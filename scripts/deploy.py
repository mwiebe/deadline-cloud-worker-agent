#!/usr/bin/env python
"""deploy.py — Upload wheels and configure an SMF fleet to use them.

Usage:
    ./deploy.py [--profile PROFILE] [--farm-id FARM] [--queue-id QUEUE] [--fleet-id FLEET] [--s3-prefix PREFIX] [--os linux|windows]

If the deadline CLI is available, missing arguments are filled from its
default configuration. If multiple SMF fleets of the target OS are
associated with the queue, the script prompts you to pick one.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_S3_PREFIX = "DeadlineCloud/custom-wheels"


def run(cmd, **kwargs):
    """Run a command and return stdout, or exit on failure."""
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        print(f"Command failed: {' '.join(cmd)}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def deadline_config_get(key):
    """Get a value from deadline CLI config, or None if unavailable."""
    try:
        return run(["deadline", "config", "get", key])
    except (FileNotFoundError, SystemExit):
        return None


def aws(args, profile=None):
    """Run an AWS CLI command and return parsed JSON."""
    cmd = ["aws"] + args + ["--output", "json"]
    if profile:
        cmd += ["--profile", profile]
    return json.loads(run(cmd))


def wait_for_fleet_active(profile, farm_id, fleet_id, timeout=120):
    """Poll until fleet status is ACTIVE or UPDATE_FAILED."""
    for _ in range(timeout // 5):
        fleet = aws(
            ["deadline", "get-fleet", "--farm-id", farm_id, "--fleet-id", fleet_id],
            profile,
        )
        status = fleet.get("status", "")
        if status == "ACTIVE":
            return
        if status == "UPDATE_FAILED":
            sys.exit(f"Fleet update failed: {fleet_id}")
        print(f"  Fleet status: {status}, waiting...")
        time.sleep(5)
    sys.exit(f"Timed out waiting for fleet {fleet_id} to become ACTIVE")


def get_smf_fleets(profile, farm_id, queue_id, os_family_filter="LINUX"):
    """Return list of (fleet_id, display_name) for SMF fleets matching the OS family."""
    assocs = aws(
        ["deadline", "list-queue-fleet-associations", "--farm-id", farm_id, "--queue-id", queue_id],
        profile,
    )
    fleets = []
    for a in assocs["queueFleetAssociations"]:
        fleet = aws(
            ["deadline", "get-fleet", "--farm-id", farm_id, "--fleet-id", a["fleetId"]],
            profile,
        )
        smf = fleet.get("configuration", {}).get("serviceManagedEc2")
        if not smf:
            continue
        os_family = smf.get("instanceCapabilities", {}).get("osFamily", "")
        if os_family == os_family_filter:
            fleets.append((a["fleetId"], fleet["displayName"]))
    return fleets


def pick_fleet(fleets, os_name):
    """Prompt user to pick a fleet if there are multiple."""
    if len(fleets) == 1:
        fleet_id, name = fleets[0]
        print(f"Using fleet: {name} ({fleet_id})")
        return fleet_id
    print(f"Multiple {os_name} SMF fleets found:")
    for i, (fid, name) in enumerate(fleets, 1):
        print(f"  {i}. {name} ({fid})")
    while True:
        choice = input(f"Select fleet [1-{len(fleets)}]: ").strip()
        if choice.isdigit() and 1 <= int(choice) <= len(fleets):
            return fleets[int(choice) - 1][0]


def main():
    parser = argparse.ArgumentParser(
        description="Deploy custom wheels to an SMF fleet.",
        epilog="""\
If --profile, --farm-id, or --queue-id are not provided, they are read from
the deadline CLI configuration (deadline config get defaults.*). If --fleet-id
is omitted, the script lists all SMF fleets of the target OS associated with
the queue and prompts you to pick one.

The S3 bucket is determined automatically from the queue's job attachment
settings. Wheels are uploaded under the S3 prefix, and the fleet's host
configuration script is set to download and install them on worker startup.
""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--profile",
                        help="AWS profile name (default: from 'deadline config get defaults.aws_profile_name')")
    parser.add_argument("--farm-id",
                        help="Deadline Cloud farm ID (default: from 'deadline config get defaults.farm_id')")
    parser.add_argument("--queue-id",
                        help="Deadline Cloud queue ID (default: from 'deadline config get defaults.queue_id')")
    parser.add_argument("--fleet-id",
                        help="Deadline Cloud fleet ID (default: auto-detected from queue's associated fleets)")
    parser.add_argument("--s3-prefix", default=DEFAULT_S3_PREFIX,
                        help=f"S3 key prefix for uploaded wheels (default: %(default)s)")
    parser.add_argument("--os", choices=["linux", "windows"], default=None,
                        help="Target OS family — selects the correct wheel and host config template "
                             "(default: auto-detected from wheels/ contents, or 'linux' if both present)")
    args = parser.parse_args()

    # Auto-detect target OS from available wheels if not specified
    if args.os:
        target_os = args.os.upper()
    else:
        wheels_dir = SCRIPT_DIR / "wheels"
        has_win = any(wheels_dir.glob("openjd_model-*win*.whl"))
        has_linux = any(w for w in wheels_dir.glob("openjd_model-*.whl")
                        if "win" not in w.name)
        if has_win and not has_linux:
            target_os = "WINDOWS"
        elif has_linux and not has_win:
            target_os = "LINUX"
        elif has_win and has_linux:
            target_os = "LINUX"  # both present, default to linux
        else:
            sys.exit("Cannot auto-detect target OS: no openjd_model wheel found in wheels/. "
                     "Pass --os explicitly.")
        print(f"Auto-detected target OS: {target_os} (from wheels/ contents)")

    # Fill defaults from deadline CLI
    profile = args.profile or deadline_config_get("defaults.aws_profile_name")
    farm_id = args.farm_id or deadline_config_get("defaults.farm_id")
    queue_id = args.queue_id or deadline_config_get("defaults.queue_id")

    if not profile:
        sys.exit("Could not determine AWS profile. Pass --profile or configure deadline CLI.")
    if not farm_id:
        sys.exit("Could not determine farm ID. Pass --farm-id or configure deadline CLI.")
    if not queue_id:
        sys.exit("Could not determine queue ID. Pass --queue-id or configure deadline CLI.")

    print(f"Profile: {profile}")
    print(f"Farm:    {farm_id}")
    print(f"Queue:   {queue_id}")

    # Resolve fleet
    fleet_id = args.fleet_id
    if not fleet_id:
        fleets = get_smf_fleets(profile, farm_id, queue_id, os_family_filter=target_os)
        if not fleets:
            sys.exit(f"No {target_os} SMF fleets found associated with this queue.")
        fleet_id = pick_fleet(fleets, target_os)

    print(f"Fleet:   {fleet_id}")
    print(f"OS:      {target_os}")

    # Get S3 bucket from queue
    queue = aws(
        ["deadline", "get-queue", "--farm-id", farm_id, "--queue-id", queue_id],
        profile,
    )
    s3_bucket = queue["jobAttachmentSettings"]["s3BucketName"]
    s3_prefix = args.s3_prefix
    print(f"S3:      s3://{s3_bucket}/{s3_prefix}/")

    # Get fleet role and ensure IAM policy for S3 access
    fleet_info = aws(
        ["deadline", "get-fleet", "--farm-id", farm_id, "--fleet-id", fleet_id],
        profile,
    )
    role_arn = fleet_info["roleArn"]
    role_name = role_arn.rsplit("/", 1)[-1]

    policy_name = "CustomWheelsS3"
    policy_doc = json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:ListBucket"],
            "Resource": [
                f"arn:aws:s3:::{s3_bucket}",
                f"arn:aws:s3:::{s3_bucket}/{s3_prefix}/*",
            ],
        }],
    })

    try:
        existing = subprocess.run(
            ["aws", "iam", "get-role-policy",
             "--role-name", role_name, "--policy-name", policy_name,
             "--profile", profile],
            capture_output=True, text=True,
        )
        if existing.returncode == 0:
            print(f"IAM policy '{policy_name}' already exists on role {role_name}")
        else:
            print(f"Adding IAM inline policy '{policy_name}' to role {role_name}...")
            run([
                "aws", "iam", "put-role-policy",
                "--role-name", role_name,
                "--policy-name", policy_name,
                "--policy-document", policy_doc,
                "--profile", profile,
            ])
            print(f"IAM policy '{policy_name}' added successfully.")
    except SystemExit:
        print(f"""
WARNING: Could not manage IAM policy. Make sure the IAM role
{role_arn}
has the following permissions (e.g. as an inline policy named '{policy_name}'):

{policy_doc}
""")

    # Upload wheels — only upload wheels relevant to the target OS
    wheels_dir = SCRIPT_DIR / "wheels"

    def find_whl(pattern):
        matches = list(wheels_dir.glob(pattern))
        if not matches:
            sys.exit(f"No wheel matching {pattern} in {wheels_dir}")
        return matches[0].name

    def find_model_whl():
        """Find the openjd-model wheel matching the target OS."""
        all_model = list(wheels_dir.glob("openjd_model-*.whl"))
        if not all_model:
            sys.exit(f"No openjd_model wheel found in {wheels_dir}")
        if target_os == "WINDOWS":
            win_whls = [w for w in all_model if "win" in w.name]
            if win_whls:
                return win_whls[0].name
        else:
            linux_whls = [w for w in all_model if "linux" in w.name or "manylinux" in w.name]
            if linux_whls:
                return linux_whls[0].name
        # Fallback: if only one wheel exists, use it
        if len(all_model) == 1:
            return all_model[0].name
        sys.exit(f"Cannot determine which openjd_model wheel to use for {target_os}. "
                 f"Found: {[w.name for w in all_model]}")

    model_whl_name = find_model_whl()
    sessions_whl_name = find_whl("openjd_sessions-*.whl")
    agent_whl_name = find_whl("deadline_cloud_worker_agent-*.whl")
    deadline_whl_name = find_whl("deadline-*.whl")

    wheels_to_upload = [model_whl_name, sessions_whl_name, agent_whl_name, deadline_whl_name]

    print(f"Uploading wheels to s3://{s3_bucket}/{s3_prefix}/")
    for whl_name in wheels_to_upload:
        run(["aws", "s3", "cp", str(wheels_dir / whl_name), f"s3://{s3_bucket}/{s3_prefix}/", "--profile", profile])

    whl_names = {
        "__MODEL_WHL__": model_whl_name,
        "__SESSIONS_WHL__": sessions_whl_name,
        "__AGENT_WHL__": agent_whl_name,
        "__DEADLINE_WHL__": deadline_whl_name,
        "__S3_BUCKET__": s3_bucket,
        "__S3_PREFIX__": s3_prefix,
    }

    # Generate host configuration script
    if target_os == "WINDOWS":
        template_file = "host-config-template.ps1"
    else:
        template_file = "host-config-template.sh"
    template = (SCRIPT_DIR / template_file).read_text()
    host_script = template
    for placeholder, value in whl_names.items():
        host_script = host_script.replace(placeholder, value)

    # Update fleet configuration and scale to zero in one call
    print("Updating fleet configuration and scaling to zero...")
    smf_config = fleet_info["configuration"]["serviceManagedEc2"]
    updated_config = json.dumps({"serviceManagedEc2": smf_config})

    run([
        "aws", "deadline", "update-fleet",
        "--farm-id", farm_id, "--fleet-id", fleet_id,
        "--configuration", updated_config,
        "--host-configuration", json.dumps({"scriptBody": host_script}),
        "--max-worker-count", "0",
        "--profile", profile,
    ])

    # Cycle fleet
    print("Waiting for fleet to become active...")
    wait_for_fleet_active(profile, farm_id, fleet_id)

    max_workers = str(fleet_info.get("maxWorkerCount", 5))
    run([
        "aws", "deadline", "update-fleet",
        "--farm-id", farm_id, "--fleet-id", fleet_id,
        "--max-worker-count", max_workers,
        "--profile", profile,
    ])

    print(f"Scaled back to {max_workers}. Workers will install custom wheels on startup.")


if __name__ == "__main__":
    main()
