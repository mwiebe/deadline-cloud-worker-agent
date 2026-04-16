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

New workers will run the host configuration script on startup, install the
custom wheels, reboot, and begin processing jobs with the updated libraries.

## Wheels included

- `openjd_model-*.whl` — Rust-backed OpenJD model library (platform-specific)
- `openjd_sessions-*.whl` — OpenJD sessions library
- `deadline_cloud_worker_agent-*.whl` — Deadline Cloud worker agent
- `deadline-*.whl` — Deadline Cloud client library

## Rebuilding

This package was created by `build-smf-deploy.sh` in the
`deadline-cloud-worker-agent/scripts/` directory. See the full docs at
`deadline-cloud-worker-agent/docs/testing-worker-agent-on-smf.md`.
