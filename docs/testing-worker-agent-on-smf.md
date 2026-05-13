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
wheels, reboot, and start processing jobs with the Rust-backed libraries.

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

## Troubleshooting

- **Host config fails**: Check the worker bootstrap log for errors.
  Common issues: S3 permissions, wrong wheel filename, Python version mismatch.
- **Workers stuck rebooting**: The `/var/lib/deadline/rebooted` marker file
  prevents infinite reboot loops. If the script fails before creating it,
  the worker will retry on next start.
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
