# SMF Deployment Package

This directory contains everything needed to deploy custom-built wheels
to a Deadline Cloud Service-Managed Fleet (SMF).

## Contents

| File | Description |
|------|-------------|
| `wheels/` | Built wheel files (platform-specific and pure Python) |
| `deploy.py` | Deployment script — uploads wheels and configures the fleet |
| `host-config-template.sh` | Linux host configuration script template |
| `host-config-template.ps1` | Windows host configuration script template |
| `README.md` | This file |

## Quick Start

```bash
# Deploy to a Linux fleet (uses deadline CLI config for defaults):
./deploy.py

# Deploy to a Windows fleet:
./deploy.py --os windows

# Explicit options:
./deploy.py --os windows --profile my-profile --farm-id farm-xxx --queue-id queue-yyy
```

Run `./deploy.py -h` for full usage details.

## What deploy.py does

1. Resolves AWS profile, farm, queue, and fleet (from args or deadline CLI config)
2. Looks up the S3 bucket from the queue's job attachment settings
3. Ensures the fleet's IAM role has S3 read access to the wheels prefix
4. Uploads the appropriate wheels to S3
5. Generates a host configuration script from the template (filling in wheel names and S3 paths)
6. Updates the fleet's host configuration and cycles it (scale to 0, then back up)

New workers will run the host configuration script on startup, install
the custom wheels, and pick up the new code. The mechanism differs by
platform:

- **Linux**: `pip install --force-reinstall` into the worker's venv at
  `/opt/deadline/worker`, then `sudo systemctl restart
  deadline-worker.service` to reload the service in place.
- **Windows**: robocopy the AMI's `C:\Program Files\Python311` to a
  sibling directory, install the wheels into the copy, and rewrite
  the `DeadlineWorker` service's `ImagePath` registry value to point
  at the copy's `pythonservice.exe`. A reboot would terminate the
  spot EC2 instance, and a clean service stop would call
  `UpdateWorker(STOPPED)` and end the worker lease, so the script
  force-kills the running `pythonservice.exe` instead.

In both cases the new agent picks up the same worker ID and re-runs
host-config, hits a marker file from the install step, and enters the
session loop with the Rust-backed wheels. See
`deadline-cloud-worker-agent/docs/testing-worker-agent-on-smf.md` for
the full design rationale.

## Wheels included

- `openjd_model-*.whl` — Rust-backed OpenJD model library (platform-specific)
- `openjd_sessions-*.whl` — OpenJD sessions library
- `deadline_cloud_worker_agent-*.whl` — Deadline Cloud worker agent
- `deadline-*.whl` — Deadline Cloud client library

## Rebuilding

This package was created by `build-smf-deploy.sh` in the
`deadline-cloud-worker-agent/scripts/` directory. See the full docs at
`deadline-cloud-worker-agent/docs/testing-worker-agent-on-smf.md`.
