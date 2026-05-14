# Testing Rust-Backed Worker Agent on Service-Managed Fleet (SMF)

Test the Rust-backed openjd libraries on a real SMF fleet by uploading
custom wheels and using a host configuration script to install them.

## Prerequisites

### Workspace layout

Set a `WORKSPACE_DIR` environment variable pointing to a directory
containing these checkouts:

| Directory | Repo | Branch / remote |
|---|---|---|
| `$WORKSPACE_DIR/openjd-rs` | `OpenJobDescription/openjd-rs` | `main` |
| `$WORKSPACE_DIR/openjd-model-for-python` | `mwiebe/openjd-model-for-python` (fork) | `bindings-rs` |
| `$WORKSPACE_DIR/openjd-sessions-for-python` | `mwiebe/openjd-sessions-for-python` (fork) | `bindings-rs` |
| `$WORKSPACE_DIR/deadline-cloud-worker-agent` | `mwiebe/deadline-cloud-worker-agent` (fork) | `bindings-rs` |
| `$WORKSPACE_DIR/deadline-cloud` | `aws-deadline/deadline-cloud` | `mainline` |

The `openjd-model-for-python/rust/Cargo.toml` has relative path
dependencies to `../../openjd-rs/crates/*`, so the repos must be
siblings in the same parent directory.

### Rust toolchain

A working Rust compiler installed via [rustup](https://rustup.rs/).
The build uses maturin to compile the PyO3 native extension.

### Fleet

- A Deadline Cloud farm with a queue and a Linux SMF fleet
- The fleet's service role must have S3 read access to the queue's job attachments bucket
- AWS CLI configured with a profile that can update fleet configuration

## Stage 1: Build the deployment directory

Run `build-smf-deploy.sh` to validate prerequisites, build all wheels,
and assemble a self-contained deployment directory:

```bash
cd $WORKSPACE_DIR/deadline-cloud-worker-agent/scripts
./build-smf-deploy.sh $WORKSPACE_DIR ~/smf-deploy
```

The script auto-detects the current platform and builds the native
maturin wheel accordingly. You can also specify `--platform linux`,
`--platform windows`, or `--platform all`.

The script:
1. Confirms all repos exist at the expected paths and branches
2. Confirms `rustc`, `cargo`, `maturin`, and `pip` are available
3. Builds the openjd-model maturin wheel (Rust native extension) for the target platform
4. Builds the openjd-sessions and deadline-cloud-worker-agent pure Python wheels
5. Builds the deadline (deadline-cloud) pure Python wheel
6. Copies wheels, host configuration script templates, and the
   deploy script into the output directory

### Building a unified (multi-platform) package

The openjd-model wheel contains native code and must be compiled on
each target platform. To create a unified deployment directory that
works for both Linux and Windows fleets:

**Option A: Build on each platform, then merge**

```bash
# On Linux:
./build-smf-deploy.sh $WORKSPACE_DIR ~/smf-deploy-linux

# On Windows (Git Bash):
./build-smf-deploy.sh $WORKSPACE_DIR ~/smf-deploy-windows

# Merge (from either platform):
./build-smf-deploy.sh --merge ~/smf-deploy-linux ~/smf-deploy-windows ~/smf-deploy
```

**Option B: Cross-compile (if toolchain is available)**

```bash
./build-smf-deploy.sh $WORKSPACE_DIR ~/smf-deploy --platform all
```

This requires `rustup target add x86_64-pc-windows-msvc` and an
appropriate linker when building from Linux.

The unified result:

```
~/smf-deploy/
├── wheels/
│   ├── openjd_model-*-manylinux*.whl
│   ├── openjd_model-*-win_amd64.whl
│   ├── openjd_sessions-*.whl
│   ├── deadline_cloud_worker_agent-*.whl
│   └── deadline-*.whl
├── host-config-template.sh
├── host-config-template.ps1
└── deploy.py
```

## Stage 2: Deploy to a fleet

Run the deploy script from the deployment directory:

```bash
cd ~/smf-deploy
./deploy.py
```

By default it targets Linux fleets. For Windows:

```bash
./deploy.py --os windows
```

If the `deadline` CLI is configured, the script automatically picks up
the AWS profile, farm ID, and queue ID from `deadline config`. It then
finds all SMF fleets of the target OS associated with the queue and
prompts you to pick one if there are multiple.

You can also pass everything explicitly:

```bash
./deploy.py --os windows --profile my-profile --farm-id farm-abc123 --queue-id queue-def456 --fleet-id fleet-xyz789
```

The script will:
1. Look up the S3 bucket from the queue's job attachment settings
2. Print a copy-pasteable IAM policy for the fleet role
3. Upload all wheels to S3
4. Set the host configuration script on the fleet (preserving existing config)
5. Cycle the fleet (scale to zero and back)

New workers will run the host configuration script, install the custom
wheels, and restart the worker-agent process in place to pick up the
new code, then start processing jobs with the Rust-backed libraries.

### Linux host-configuration flow

The Linux host-configuration script (`host-config-template.sh`):

1. Compares a content-keyed marker
   (`/var/lib/deadline/custom-wheels-installed`) against the wheel set
   the deploy expects. If they match, exits 0 immediately — nothing to
   do. This makes the script idempotent across host-config invocations.
2. Otherwise, downloads each wheel from S3, `pip install --force-reinstall
   --no-deps` into the worker venv at `/opt/deadline/worker`, and re-runs
   `chmod -R go+rx` so the unprivileged service user can still read it.
3. **Pre-restart sanity check**: runs `python -c "import openjd.model;
   import openjd.sessions; import openjd._openjd_rs; import
   deadline.client; import deadline_worker_agent"` and
   `deadline-worker-agent --help`. If anything here fails, the script
   exits non-zero **before** the restart — the existing (working) agent
   keeps running and the failure is visible in the CloudWatch host-config
   log instead of vanishing behind a reboot.
4. Writes the marker file so subsequent host-config invocations skip
   straight to step 1.
5. `sudo systemctl restart deadline-worker.service`. Systemd kills the
   current agent (and this script with it), then starts a fresh agent
   with the newly-installed wheels. The CloudWatch agent stays
   connected across the swap, so any crash on the new agent's startup
   surfaces in the same log stream — typically within ~3 seconds of the
   `Restarting deadline-worker service...` line.

The new agent re-runs the host-config script on startup. The marker is
already in place, so it short-circuits to "Custom wheels already
installed", logs "Worker Agent host configuration succeeded", and enters
the worker session loop with the Rust-backed wheels.

## What to verify

- Worker logs show `openjd.model: 0.9.x.post<N>+g<hash>` (and a similar
  `0.10.x.post<N>+g<hash>` for `openjd.sessions`) in the AgentInfo
  section. The `.post<N>+g<hash>` local segment confirms the
  `bindings-rs` dev build is loaded; a plain released version like
  `0.9.0` means the wheel install hit the wrong Python or didn't
  replace the AMI's PyPI version.
- Host configuration script logs show successful wheel installation
- Jobs complete successfully with correct session logs
- CloudWatch session logs have properly ordered timestamps
- `openjd_env` commands from queue environments work (e.g. PATH is set)

### Linux-specific signals during deploy

In the worker's CloudWatch log stream
(`/aws/deadline/<farm-id>/<fleet-id>` → stream
`worker-<worker-id>`), look for the host-configuration script's own
output in addition to the AgentInfo check above:

- `=== Pre-restart sanity: imports ===` block lists each module loaded
  with the expected post-release version, e.g.
  `openjd.model    : 0.9.1.post10+g678259513.d20260513 from
  /opt/deadline/worker/lib64/python3.11/site-packages/openjd/model/__init__.py`.
- `Restarting deadline-worker service...` followed (within ~3 seconds)
  by a fresh `Running host configuration script.` and `Worker Agent
  host configuration succeeded. Starting worker session loop.` from the
  new agent.
- Subsequent worker re-creations on the same host
  (e.g. after Deadline Cloud's worker lease cycles) skip the install
  block entirely with `Custom wheels already installed (marker matches).
  Skipping.`.

Then submit a small job and verify:

- All tasks reach `SUCCEEDED`.
- Session logs (under
  `/aws/deadline/<farm-id>/<queue-id>` → stream `session-<id>`) show
  task stdout/stderr and any `openjd_progress` updates.

## Troubleshooting

- **Host config fails before the restart** (Linux): The script exits
  non-zero from one of the pre-restart sanity steps (imports or
  `--help`). The existing pre-Rust agent keeps running. Look in the
  worker's CloudWatch log for the `=== Pre-restart sanity: imports
  ===` block and the traceback that follows. Common causes:
    - **`ModuleNotFoundError: No module named 'openjd.model._version'`**
      — the wheel was built without `_version.py`. Confirm
      `[tool.maturin] include = [{ path = "openjd/model/_version.py",
      format = "wheel" }]` is set in
      `openjd-model-for-python/pyproject.toml`, then rebuild.
    - **`AttributeError: module 'openjd.model' has no attribute
      '__version__'`** — the import sanity uses
      `openjd.model.version`, not `__version__`. If you customize the
      check, match the package's actual surface.
    - S3 download error or wrong wheel filename.
    - Python version mismatch between the AMI and the wheel's ABI tag.
- **Worker reaches `STARTED` then drops to `STOPPING` quickly** (Linux):
  the new agent crashed after `systemctl restart`. Look for events in
  the same CloudWatch log stream after `Restarting deadline-worker
  service...` — the new agent uses the same stream, so any startup
  crash surfaces there within a few seconds. (If you see no events at
  all after the restart line, the systemd unit may have failed to
  start; check `systemctl status deadline-worker.service` in the
  on-host journal — but in practice this is rare because the pre-restart
  sanity gate catches most issues.)
- **Wrong platform wheel**: The openjd-model wheel must match the SMF
  platform. AL2023 uses glibc 2.34+. Build with maturin in a matching
  environment or use `--target`.

## Windows SMF Fleets

The unified deployment directory supports both Linux and Windows fleets.
The `--os windows` flag on `deploy.py` selects the correct wheel and
uses the PowerShell host configuration template.

### Windows-specific notes

- The host configuration script is PowerShell (`host-config-template.ps1`)
- The marker file is at `C:\ProgramData\Amazon\Deadline\rebooted`
- The worker venv is activated via
  `C:\ProgramData\Amazon\Deadline\worker\bin\activate.ps1`
- Wheels are downloaded to `C:\temp\deadline-wheels\`
- The openjd-model wheel must be `*win_amd64*.whl` — either built
  natively on Windows or cross-compiled with `--target x86_64-pc-windows-msvc`

### Windows troubleshooting

- **Host config fails**: Check CloudWatch worker bootstrap logs.
  On Windows, ensure the fleet service role has S3 access and the
  wheel filenames match the Python version on the AMI.
- **Workers stuck rebooting**: The `C:\ProgramData\Amazon\Deadline\rebooted`
  marker prevents infinite reboot loops.
- **Wrong platform wheel**: The openjd-model wheel must be built for
  `win_amd64`. If cross-compiling, ensure the MSVC target is installed.
