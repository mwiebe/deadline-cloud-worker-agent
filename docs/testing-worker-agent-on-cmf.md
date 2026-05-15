# Testing Rust-Backed Worker Agent Locally on a CMF

Run the Rust-backed worker agent as your unprivileged user against a
Customer-Managed Fleet (CMF), without installing the wheels system-wide
and without needing `sudo` (Linux) or Administrator (Windows).

This is the local analogue of the AWS Developer Guide's
[Run the Deadline Cloud worker agent][run-worker] tutorial, adapted to:

1. Pick up locally-built Rust-backed wheels (`openjd-model`,
   `openjd-sessions`) instead of the PyPI versions.
2. Write all state (logs, persistence, session scratch) under your home
   directory so no privileged step is required.

See [`testing-worker-agent-on-smf.md`](./testing-worker-agent-on-smf.md)
for the SMF flow.

[run-worker]: https://docs.aws.amazon.com/deadline-cloud/latest/developerguide/run-worker.html

## Prerequisites

### Workspace layout

Same as the SMF doc — you need sibling checkouts:

| Directory | Repo | Branch / remote |
|---|---|---|
| `$WORKSPACE_DIR/openjd-rs` | `OpenJobDescription/openjd-rs` | `main` |
| `$WORKSPACE_DIR/openjd-model-for-python` | `mwiebe/openjd-model-for-python` (fork) | `bindings-rs` |
| `$WORKSPACE_DIR/openjd-sessions-for-python` | `mwiebe/openjd-sessions-for-python` (fork) | `bindings-rs` |
| `$WORKSPACE_DIR/deadline-cloud-worker-agent` | `mwiebe/deadline-cloud-worker-agent` (fork) | `bindings-rs` |
| `$WORKSPACE_DIR/deadline-cloud` | `aws-deadline/deadline-cloud` | `mainline` |

The `openjd-model-for-python/rust-bindings/Cargo.toml` has relative path
dependencies into `../../openjd-rs/crates/*`, so the checkouts must be
siblings in the same parent directory.

### Tooling

- Python 3.9+ (matching an AMI target is not required for local testing)
- A working Rust compiler installed via [rustup](https://rustup.rs/)
- `pip`, `virtualenv` or `python -m venv`
- `maturin` (installed into the venv below)
- AWS CLI configured with a profile that can call `CreateWorker` and
  `GetWorkerIamCredentials` (either via direct permissions or by assuming
  the fleet bootstrapping role)
- A farm, queue, and CMF already set up, per
  [Create a Deadline Cloud farm][create-farm]

[create-farm]: https://docs.aws.amazon.com/deadline-cloud/latest/developerguide/create-a-farm.html

## Step 1: Create a venv and install the Rust-backed wheels

All wheels are installed into one project-local venv. Nothing touches
system Python paths or requires elevated permissions.

### Linux / macOS

```bash
cd $WORKSPACE_DIR
python -m venv .venv-worker
source .venv-worker/bin/activate
pip install --upgrade pip maturin setuptools_scm
```

### Windows (Git Bash, PowerShell, or Conda)

If using a conda environment or an existing venv, activate it first.
If creating a new venv:

```bash
cd $WORKSPACE_DIR
python -m venv .venv-worker
# Git Bash:
source .venv-worker/Scripts/activate
# PowerShell:
# .venv-worker\Scripts\Activate.ps1
pip install --upgrade pip maturin setuptools_scm
```

> **Note (maturin venv detection):** `maturin develop` looks for the
> target environment via `VIRTUAL_ENV` or `CONDA_PREFIX` environment
> variables. If neither is set (e.g. conda base env on Windows not
> activated with `conda activate`), set `VIRTUAL_ENV` explicitly:
>
> ```bash
> export VIRTUAL_ENV="/path/to/your/python/prefix"
> ```
>
> Also ensure there is no `.venv` directory inside
> `openjd-model-for-python` — maturin will prefer that over the active
> environment. Rename or remove it if present.

### Build and install `openjd-model` (Rust-backed, native)

```bash
cd $WORKSPACE_DIR/openjd-model-for-python
python scripts/maturin_build.py develop --release --manifest-path rust-bindings/Cargo.toml
```

The wrapper invokes `maturin develop` after computing a VCS-derived
version (e.g. `0.9.1.post9+gee56e5417`) from `setuptools_scm`, writing
it to `src/openjd/model/_version.py`, and temporarily patching
`pyproject.toml`'s `[project].version` so `maturin` stamps the same
string into the wheel metadata. The patch is reverted in `finally` —
the working tree stays clean.

`maturin develop` is the fastest rebuild path during dev. If you
prefer plain pip, `pip install -e .` also works — the package's
in-tree PEP 517 backend (`_build_backend.py`) does the same patching
around maturin's hooks, so the wheel still ends up with the VCS
version. Calling `maturin develop` directly (no wrapper) skips the
PEP 517 backend and produces a wheel labeled with the static `0.9.0`
from `Cargo.toml` that won't match the in-Python `__version__`.

### Install `openjd-sessions` (pure Python, editable)

```bash
pip install -e $WORKSPACE_DIR/openjd-sessions-for-python
```

### Install `deadline` (deadline-cloud client, editable)

```bash
pip install -e $WORKSPACE_DIR/deadline-cloud
```

### Install the worker agent (editable)

```bash
pip install -e $WORKSPACE_DIR/deadline-cloud-worker-agent
```

The `bindings-rs` branch of the worker agent loosens its
`openjd-sessions` pin to `>= 0.10.7, < 0.11` so pip's resolver accepts
the editable `0.10.7.postN+gHASH` dev build. On the upstream `mainline`
branch the pin is `== 0.10.7`, which excludes post-releases under PEP
440 and forces a re-resolve from PyPI — if you ever install from that
branch into this venv, pass `--no-deps` to `pip install -e .` to keep
the local install.

### Verify

```bash
python -c "import openjd.model; print('openjd.model from:', openjd.model.__file__)"
python -c "from openjd._openjd_rs import __doc__; print('rust ext OK')"
deadline-worker-agent --help
```

`openjd.model.__file__` should point inside
`$WORKSPACE_DIR/openjd-model-for-python/src/openjd/model/__init__.py`,
confirming the local editable install was picked up and not a stale
PyPI version.

## Step 2: Create user-writable directories

Create a scratch area under your home directory for the three paths that
would otherwise default to privileged locations:

| Linux/macOS default | Windows default | Override flag | Purpose |
|---|---|---|---|
| `/var/log/amazon/deadline` | `C:\ProgramData\Amazon\Deadline\Logs` | `--logs-dir` | Agent log files |
| `/var/lib/deadline` | `C:\ProgramData\Amazon\Deadline\Data` | `--persistence-dir` | Worker ID, credentials, state |
| `/sessions` | `C:\ProgramData\Amazon\Deadline\Sessions` | `--session-root-dir` | Per-session scratch directories |

```bash
mkdir -p ~/devenv-logs ~/devenv-persist ~/devenv-sessions
```

## Step 3: Set farm, fleet, and credentials

Set your farm ID, fleet ID, and region:

```bash
export DEV_FARM_ID=farm-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export DEV_CMF_ID=fleet-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export AWS_DEFAULT_REGION=us-west-2  # or your region
```

### Option A: Use an AWS profile directly

If your AWS profile has permissions to call `CreateWorker` and
`GetWorkerIamCredentials` on the fleet (e.g. an Admin role):

```bash
export AWS_PROFILE=MyProfile
```

Then pass `--profile MyProfile` to the agent, or rely on `AWS_PROFILE`.

### Option B: Assume the fleet bootstrapping role

If your profile cannot directly bootstrap workers, assume the fleet role:

```bash
# Linux/macOS:
source $WORKSPACE_DIR/deadline-cloud-worker-agent/scripts/assume_role_to_env.sh \
    arn:aws:iam::<account>:role/<BootstrappingRole>

# Windows (Git Bash) — same script works if jq is installed.
# Windows (PowerShell) alternative:
$creds = aws sts assume-role --role-arn "arn:aws:iam::<account>:role/<BootstrappingRole>" --role-session-name WorkerAgentLocalTest | ConvertFrom-Json
$env:AWS_ACCESS_KEY_ID = $creds.Credentials.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $creds.Credentials.SecretAccessKey
$env:AWS_SESSION_TOKEN = $creds.Credentials.SessionToken
```

## Step 4: Run the agent

```bash
deadline-worker-agent \
    --farm-id "$DEV_FARM_ID" \
    --fleet-id "$DEV_CMF_ID" \
    --run-jobs-as-agent-user \
    --logs-dir ~/devenv-logs \
    --persistence-dir ~/devenv-persist \
    --session-root-dir ~/devenv-sessions \
    --no-shutdown \
    --verbose
```

What each flag does:

- `--run-jobs-as-agent-user`: disables cross-user impersonation. All
  session actions run as your current user. **Dev-only — insecure
  against untrusted jobs.**
- `--logs-dir ~/devenv-logs`: writes agent and session logs here.
- `--persistence-dir ~/devenv-persist`: writes the worker ID and
  credential cache here.
- `--session-root-dir ~/devenv-sessions`: per-session scratch dirs are
  created under this path.
- `--no-shutdown`: don't shut down the host when the service asks the
  worker to stop.
- `--verbose`: more detailed console logging — useful when diagnosing
  Rust-backed behavior.

On startup the agent logs an `AgentInfo` block. For the Rust-backed
build this should include:

```
Dependency versions installed:
    openjd.model: 0.9.0.post<N>+g<hash>
    openjd.sessions: 0.10.7.post<N>+g<hash>
    ...
```

The `.post<N>+g<hash>` local segment (generated by `setuptools_scm` /
`hatch-vcs` from the dev-checkout's git state) is the signal that the
worker agent is loading the local editable install of the Rust-backed
`bindings-rs` branches. A plain released version like `0.9.0` instead
means pip resolved to the PyPI Pydantic build — see the Troubleshooting
section.

## Step 5: Submit a job

From a second shell (or after stopping the agent with Ctrl-C):

```bash
# Activate the same environment used above
deadline config set defaults.farm_id "$DEV_FARM_ID"
deadline config set defaults.queue_id "$DEV_QUEUE_ID"

# Small sleep job from this repo:
cd $WORKSPACE_DIR/deadline-cloud-worker-agent
scripts/submit_jobs/sleep/submit_sleep.sh
```

Or any job bundle:

```bash
deadline bundle submit ~/deadline-cloud-samples/job_bundles/<bundle>
```

## Step 6: Verify

Agent side:

- Agent log under `~/devenv-logs/worker-agent.log` should show the job
  assignment.
- Session logs under `~/devenv-logs/queue-*/session-*.log` should show
  the task's stdout/stderr.
- `~/devenv-sessions/session-*/` should exist during the session and
  be cleaned up after (unless `--retain-session-dir` is passed).

Service side:

```bash
deadline worker list --fleet-id "$DEV_CMF_ID"
deadline job list
```

## Tear-down

Stop the agent with Ctrl-C. To reset state for a fresh worker ID on the
next run:

```bash
rm -rf ~/devenv-logs ~/devenv-persist ~/devenv-sessions
mkdir -p ~/devenv-logs ~/devenv-persist ~/devenv-sessions
```

The service-side worker record stays registered unless you delete it
via `deadline delete-worker`.

## Troubleshooting

- **`openjd.model.__file__` points to site-packages, not the workspace**
  — the venv still has a cached PyPI install. Reinstall:
  `pip uninstall -y openjd-model && cd $WORKSPACE_DIR/openjd-model-for-python && python scripts/maturin_build.py develop --release --manifest-path rust-bindings/Cargo.toml`.
- **`ImportError: cannot import name 'Environment' from 'openjd.model'`**
  — The Rust-backed v1 package doesn't export the old Pydantic
  `Environment` symbol at the top level. This means the worker agent or
  one of its dependencies is still on a pre-`bindings-rs` commit. Make
  sure all five repos are on the branches in the prerequisites table.
- **`ModuleNotFoundError: No module named 'openjd._openjd_rs'`** —
  `maturin develop` installed the native extension into the wrong
  environment. Check `VIRTUAL_ENV` / `CONDA_PREFIX` is set correctly,
  and that there is no `.venv` directory inside `openjd-model-for-python`
  that maturin is preferring over your active environment.
- **Permission denied writing to `/sessions` or `/var/...`** (Linux), or
  **Access denied writing to `C:\ProgramData\...`** (Windows) — you
  forgot `--session-root-dir` / `--logs-dir` / `--persistence-dir`, or
  a config file (`/etc/amazon/deadline/worker.toml` on Linux,
  `C:\ProgramData\Amazon\Deadline\worker.toml` on Windows) is overriding
  them. The worker agent merges CLI args on top of env vars on top of
  the config file, so CLI flags win — but the config file is still
  loaded if it exists. Move or rename it while testing.
- **`NoRegionError: You must specify a region`** — set
  `AWS_DEFAULT_REGION` in your environment. The agent's telemetry code
  creates a bare boto3 client that doesn't pick up `--profile`'s region.
- **Worker registers but immediately goes `NOT_RESPONDING`** — the
  agent probably crashed on startup. Check `~/devenv-logs/` for a
  traceback, and re-run with `--verbose`.
- **Jobs fail with `jobRunAsUser` errors** — `--run-jobs-as-agent-user`
  only takes effect if the queue was created with
  `runAs: QUEUE_CONFIGURED_USER` (or equivalent) _and_ the fleet permits
  it. If the queue hard-requires a specific `jobRunAsUser`, you'll need
  to either match that user locally or recreate the queue for local
  testing.
- **UnicodeEncodeError with rich logging on Windows** — the `rich`
  console handler may fail to render emoji on legacy Windows terminals
  (cp1252). Set `PYTHONIOENCODING=utf-8`. The agent still runs — this
  only affects console output, not the log file.

## Comparison with the SMF flow

| Aspect | CMF (this doc) | SMF ([`testing-worker-agent-on-smf.md`](./testing-worker-agent-on-smf.md)) |
|---|---|---|
| Worker host | Your laptop / dev VM (Linux or Windows) | EC2 instance managed by Deadline Cloud |
| Install | `pip install -e` + `maturin develop` in a venv | Wheels built by `build-smf-deploy.sh`, uploaded to S3, installed by host-config script |
| Rebuild loop | Fast — `maturin develop` on a source change, restart agent | Slow — rebuild wheels, redeploy, cycle fleet |
| Privileged setup | None (everything under `$HOME` / `%USERPROFILE%`) | None you manage directly |
| Cross-user impersonation | Disabled (`--run-jobs-as-agent-user`) | Real (`jobuser` on Linux AMI, configured user on Windows) |
| Best for | Iterative debugging, breakpoints in Python, fast feedback | End-to-end validation, cross-user code paths, production-like fleets |
