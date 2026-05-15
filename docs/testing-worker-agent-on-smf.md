# Testing Rust-Backed Worker Agent on Service-Managed Fleet (SMF)

Test the Rust-backed openjd libraries on a real SMF fleet by uploading
custom wheels and using a host configuration script to install them.

## Why this flow differs from the generic SMF custom-worker pattern

The generic "custom worker on SMF" pattern (see the
[`custom-worker-on-smf` skill](../skills/custom-worker-on-smf/SKILL.md))
does `pip install git+...` from the host configuration script and then
**reboots** the worker. That works for pure-Python changes against a
single repo. The Rust-bindings build needs a different shape:

- **Native extension build, not pure pip-from-Git.** `openjd-model`
  ships a PyO3 native extension built with maturin. The wheel must
  match the SMF AMI's libc / Python ABI / architecture (manylinux
  glibc 2.34+ on AL2023, `win_amd64` on Windows). Asking the worker
  to build this on boot would require shipping a Rust toolchain into
  the host-config script and would fight the AMI's glibc on every
  start.
- **Cross-repo path dependencies.** `openjd-model-for-python/rust-bindings/Cargo.toml`
  has relative path deps to `../../openjd-rs/crates/*`, and the model
  wheel itself is built by an in-tree PEP 517 backend
  (`_build_backend.py`) that injects a VCS-derived
  `0.9.x.post<N>+g<hash>` version. Reproducing that on the worker
  from `git+` URLs would require pulling all five repos and
  reproducing the workspace layout — `pip` can't do that.
- **Multi-package coordinated install.** A bindings-rs deploy
  swaps four wheels (`openjd-model`, `openjd-sessions`,
  `deadline-cloud-worker-agent`, `deadline-cloud`) as a set. Building
  them once at deploy time and uploading the matched set to S3 keeps
  the version triple consistent across workers and avoids each worker
  resolving Git refs independently.
- **Restart-in-place instead of reboot (Linux).** The generic
  skill's `sudo reboot now` is reliable but blind: if the new agent
  fails to come back up, the previous CloudWatch log stream ends and
  the failure is invisible until the next worker registers. This
  flow uses `systemctl restart deadline-worker.service` so the
  CloudWatch agent stays connected and the new agent's startup
  surfaces in the same log stream within seconds.
- **Pre-restart sanity gate.** Before the restart, the script
  imports every key module and runs `deadline-worker-agent --help`.
  Failures here exit non-zero **without** restarting — the existing
  agent keeps running and the failure is visible in the host-config
  log. The reboot-based generic flow has no equivalent: any
  post-install error appears (if at all) only after the host comes
  back up.
- **Content-keyed idempotency marker.** The marker file
  (`/var/lib/deadline/custom-wheels-installed` on Linux,
  `C:\ProgramData\Amazon\Deadline\bindings-rs-installed` on Windows)
  is keyed on the **wheel filenames** rather than just existing or
  not. New deploys with new wheels invalidate the marker
  automatically; redeploying the same wheel set is a fast no-op.
- **`--force-reinstall --no-deps`.** Each wheel is installed with
  `--force-reinstall --no-deps` so the AMI's PyPI-installed versions
  are overwritten and pip can't pull in transitive updates that
  would diverge from the tested wheel set.
- **Windows can't restart in place.** `pythonservice.exe` holds
  `openjd._openjd_rs.pyd` memory-mapped, and any clean
  `Stop-Service` / `Restart-Computer` would terminate the spot
  lease. The Windows flow does a parallel-tree install plus a
  registry-repointed force-kill instead — see the *Windows
  host-configuration flow* section below.
- **Side debug log + S3 watchdog (Windows).** The Windows swap
  kill-and-restart can drop output from the CloudWatch agent. The
  host-config script writes a side log to
  `C:\ProgramData\Amazon\Deadline\bindings-rs-debug.log` and spawns
  a watchdog that uploads it (and the worker-agent logs) to S3 every
  10s for 30 min, so the swap window stays diagnosable.

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

The `openjd-model-for-python/rust-bindings/Cargo.toml` has relative path
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

The Linux host-configuration script (`host-config-template.sh`) is
*restart-in-place*, not reboot-based — see the rationale section at
the top of this doc. The script:

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

### Windows host-configuration flow

The Windows host-configuration script (`host-config-template.ps1`) can't
use the same restart-in-place pattern as Linux. Two Windows + SMF
constraints rule it out:

1. **`pythonservice.exe` holds the old `.pyd`.** The running Windows
   service has `openjd._openjd_rs.pyd` (the PyO3 native extension)
   memory-mapped. `pip install --force-reinstall` either fails on
   file-in-use or writes a new file that the live import cache will
   ignore. Restarting just the service inside the same Python tree
   would still leave the old extension loaded the next time
   pythonservice.exe respawns from the same `python311.dll`.
2. **Reboots and clean shutdowns end the spot lease.** A guest-side
   `Restart-Computer` doesn't bring the same EC2 instance back —
   Deadline Cloud terminates the spot allocation. A clean
   `Stop-Service` is just as bad: the agent's normal shutdown path
   calls `UpdateWorker(STOPPED)`, which Deadline interprets as
   "worker is done", with the same outcome.

The Windows script therefore does a parallel install and then
atomically repoints the service:

1. **Robocopy** `C:\Program Files\Python311` to a sibling directory
   `Python311-bindings-rs` (`/MIR /XJ`).
2. **pip-install** the four bindings-rs wheels into the new tree using
   its own `python.exe` (so the running service's site-packages is
   never touched).
3. **Smoke-test** `import openjd.model` from the new interpreter. If
   the import fails, the script throws *before* touching the registry
   — the running service is untouched and the failure is visible in
   both CloudWatch and a side log
   (`C:\ProgramData\Amazon\Deadline\bindings-rs-debug.log`).
4. **Drop a marker file**
   (`C:\ProgramData\Amazon\Deadline\bindings-rs-installed`) so the
   host-config run that the *post-swap* agent triggers on startup is a
   no-op.
5. **Spawn a detached child PowerShell.** It waits 3 s, rewrites
   `HKLM:\SYSTEM\CurrentControlSet\Services\DeadlineWorker\ImagePath`
   to the new tree's `pythonservice.exe`, then **force-kills** the
   running `pythonservice.exe` with `Stop-Process -Force` (not
   `Stop-Service` — that would trigger the spot-terminating clean
   shutdown). The child waits for SCM to mark the service Stopped,
   then either lets SCM auto-recovery restart the service or calls
   `Start-Service` explicitly.
6. **Block the host-config script in `Start-Sleep -Seconds 60` after
   spawning the child.** The child's force-kill terminates the script
   mid-sleep before it can `exit 0`. This is deliberate: if the script
   *did* return 0, the agent would record
   `host_configuration_succeeded=True` and immediately enter the
   session loop, picking up a queued job whose session would then be
   abandoned when the kill fires. By dying mid-script, the agent
   never enters the session loop, and the post-swap agent inherits a
   clean state.
7. **The post-swap agent re-runs host-config.** The marker file from
   step 4 short-circuits the install path; the script returns 0
   cleanly, the agent records `host_configuration_succeeded=True`,
   and only then enters the session loop.

The whole swap is invisible to Deadline: the service comes back with
the same worker ID (read from `Cache\worker.json`), so jobs queue and
schedule normally on it.

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
uses the PowerShell host configuration template
(`host-config-template.ps1`). See *Windows host-configuration flow*
above for the design rationale.

### Windows-specific notes

- **Source Python tree**: `C:\Program Files\Python311` (the system-wide
  Python the SMF AMI's `pythonservice.exe` runs out of). The host-config
  script auto-detects this; if it's missing, it falls back to parsing
  the `DeadlineWorker` service's `ImagePath` registry value.
- **Parallel install**: `C:\Program Files\Python311-bindings-rs`. The
  `pip install` and the post-swap `pythonservice.exe` both run out of
  this tree.
- **Marker file**:
  `C:\ProgramData\Amazon\Deadline\bindings-rs-installed`. Written
  before the service swap; the post-swap host-config run sees it and
  exits 0 without re-installing.
- **Side debug log**:
  `C:\ProgramData\Amazon\Deadline\bindings-rs-debug.log`. The
  host-config script and the detached service-swap child both append
  here, and a subsequent host-config run echoes the prior log to
  stdout — useful for diagnosing failures across the kill-and-restart
  cycle since the CloudWatch log stream may miss output during the
  swap.
- **Wheel download dir**: `C:\temp\deadline-wheels\`.
- **Wheel platform tag**: the openjd-model wheel must be `*win_amd64*`,
  built natively on Windows or cross-compiled with
  `--target x86_64-pc-windows-msvc`.

### Windows troubleshooting

- **Smoke test fails before the swap**: the script throws "Smoke test
  failed with exit code N — refusing to repoint the service." The
  running service is untouched. Check CloudWatch and the side debug
  log for the actual import error. Common causes are the same as
  Linux (missing `_version.py`, wrong wheel ABI tag) plus a
  Windows-specific one: the openjd-model wheel was built for the
  wrong architecture or a different Python ABI than the one in
  `Python311-bindings-rs`.
- **Worker comes back as a NEW worker ID after the swap** (instead of
  re-using the old one): the service was stopped through its clean
  shutdown path, not force-killed. The agent's
  `UpdateWorker(STOPPED)` made Deadline retire the worker and the
  spot allocation, and the post-swap pythonservice.exe started up as
  a fresh instance and registered a new worker. Check the side debug
  log for `Stop-Process` errors.
- **Host-config script slept past kill window**: the script logs
  "ERROR: host-config script slept past kill window. Detached child
  failed to fire." and exits 2. The detached child either failed to
  start, failed to identify the running PID, or `Stop-Process` was
  blocked. The side debug log will have details.
- **Wrong platform wheel**: see the wheel platform tag note above.
