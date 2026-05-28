# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
set -xeuo pipefail

S3_BUCKET="__S3_BUCKET__"
S3_PREFIX="__S3_PREFIX__"
MODEL_WHL="__MODEL_WHL__"
SESSIONS_WHL="__SESSIONS_WHL__"
AGENT_WHL="__AGENT_WHL__"
DEADLINE_WHL="__DEADLINE_WHL__"

# The marker file tracks which wheel set has been installed on this host.
# If the content matches what we're about to install, we're done — no-op.
# If it differs (e.g. after a deploy pushed new wheels), we install and
# restart the agent in-place. This avoids a reboot cycle, which was the
# previous implementation's approach but made post-install failures
# invisible (the worker agent couldn't re-register, so no further
# CloudWatch logs appeared).
MARKER=/var/lib/deadline/custom-wheels-installed
EXPECTED="$MODEL_WHL $SESSIONS_WHL $AGENT_WHL $DEADLINE_WHL"

echo "Running host configuration script to install Rust-backed openjd libraries."

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$EXPECTED" ]; then
    echo "Custom wheels already installed (marker matches). Skipping."
    exit 0
fi

# Download wheels
for WHL in $MODEL_WHL $SESSIONS_WHL $AGENT_WHL $DEADLINE_WHL; do
    echo "Downloading $WHL from s3://$S3_BUCKET/$S3_PREFIX/$WHL"
    aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$WHL" /tmp/
done

# Install into the worker's venv
# (source first so pip installs into the right place)
source /opt/deadline/worker/bin/activate

pip install /tmp/$MODEL_WHL --force-reinstall --no-deps
pip install /tmp/$SESSIONS_WHL --force-reinstall --no-deps
pip install /tmp/$AGENT_WHL --force-reinstall --no-deps
pip install /tmp/$DEADLINE_WHL --force-reinstall --no-deps

deactivate

# Re-apply directory permissions the pip installs may have altered so the
# deadline-worker service user can still read its venv.
chmod -R go+rx /opt/deadline/worker

echo "Installed packages:"
# Defensive: grep failing (no matches) shouldn't kill the script under
# `set -eo pipefail`. Use `|| true` to absorb non-zero grep exit codes.
/opt/deadline/worker/bin/pip list | grep -iE "openjd|deadline" || true

# Pre-restart sanity checks: exercise the same imports and commands the
# agent will perform on startup, surfacing any error in the CURRENT
# CloudWatch log stream. If anything here fails, we abort without
# restarting — the current (working, pre-Rust) agent keeps running and
# the failure is visible in the host-config log.
echo "=== Pre-restart sanity: imports ==="
/opt/deadline/worker/bin/python -c "
import openjd.model
print(f'  openjd.model    : {openjd.model.version} from {openjd.model.__file__}')
import openjd.sessions
print(f'  openjd.sessions : from {openjd.sessions.__file__}')
import openjd._openjd_rs as rs
print(f'  _openjd_rs      : native ext OK')
import deadline.client
print(f'  deadline.client : loaded')
import deadline_worker_agent
print(f'  worker agent    : loaded')
"

echo "=== Pre-restart sanity: --help ==="
/opt/deadline/worker/bin/deadline-worker-agent --help > /dev/null
echo "  --help OK"

# Record what's installed — before the restart, so if the restart fails
# we don't loop on the next bootstrap.
mkdir -p "$(dirname "$MARKER")"
echo "$EXPECTED" > "$MARKER"
chmod 644 "$MARKER"

# Restart the worker agent in place. The systemd service auto-restarts
# on failure; we explicitly trigger a restart so the newly-installed
# wheels are picked up. The machine stays up, the CloudWatch agent stays
# connected, so any crash-on-restart surfaces in CloudWatch logs in real
# time instead of vanishing behind a reboot.
echo "Restarting deadline-worker service..."
sudo systemctl restart deadline-worker.service

# Give systemd a moment to kick off the process, then confirm it's up.
sleep 3
if systemctl is-active --quiet deadline-worker.service; then
    echo "deadline-worker.service is active after restart."
else
    echo "ERROR: deadline-worker.service failed to come up after restart." >&2
    systemctl status deadline-worker.service --no-pager || true
    journalctl -u deadline-worker.service -n 100 --no-pager || true
    exit 1
fi
