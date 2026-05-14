# Belt-and-suspenders debug: write to a side log so we can see the script
# even started, regardless of whether the agent's tee captures our output.
# Also echo any prior version of this debug log to stdout so a future
# host-config run can show what happened in earlier runs.
$debugLog = "C:\ProgramData\Amazon\Deadline\bindings-rs-debug.log"
if (Test-Path $debugLog) {
    Write-Host "=== begin PRIOR bindings-rs-debug.log ==="
    Get-Content $debugLog -Encoding utf8 | ForEach-Object { Write-Host $_ }
    Write-Host "=== end PRIOR bindings-rs-debug.log ==="
}
function _DLog { param($m) "$(Get-Date -Format o)  $m" | Out-File -FilePath $debugLog -Encoding utf8 -Append }
_DLog "=== host-config script started"
_DLog "PSVersion: $($PSVersionTable.PSVersion)"
_DLog "PWD: $(Get-Location)"
_DLog "PID: $PID"
_DLog "user: $env:USERNAME"

# We default to 'Continue' for the bulk of the script (so a single
# noisy native-command stderr write doesn't terminate everything),
# and switch to 'Stop' explicitly inside the try/catch wrap below.
$ErrorActionPreference = "Continue"

$S3_BUCKET = "__S3_BUCKET__"
$S3_PREFIX = "__S3_PREFIX__"
$MODEL_WHL = "__MODEL_WHL__"
$SESSIONS_WHL = "__SESSIONS_WHL__"
$AGENT_WHL = "__AGENT_WHL__"
$DEADLINE_WHL = "__DEADLINE_WHL__"

# Parallel-install strategy (Windows SMF):
#
# Two Windows + SMF constraints rule out the patterns that work on
# Linux:
#
#   1. We can't replace the agent's own modules in place. The running
#      pythonservice.exe has the old `openjd._openjd_rs.pyd` mapped
#      (file-in-use prevents overwrite), and even where pip succeeds
#      in writing a new file the live import cache keeps returning the
#      old `openjd.model`. `pip install --force-reinstall` is at best
#      a no-op for the running interpreter.
#
#   2. We can't reboot the EC2 instance, and we can't take the
#      service down through its normal "stop" path. On SMF spot,
#      an in-guest reboot or a clean agent shutdown
#      (UpdateWorker(STOPPED)) tells Deadline the worker is done and
#      Deadline terminates the spot allocation -- the host doesn't
#      come back as the same EC2 instance.
#
# Instead, build a parallel Python tree, install the new wheels into
# it, and atomically repoint the SCM's ImagePath at the new tree's
# pythonservice.exe so the next service start uses the new code.
# pythonservice.exe is not bound at build time to a specific Python
# install -- it loads pythonXY.dll via DLL adjacency, so a copied
# tree resolves to its own site-packages. ImagePath is the only
# registry value that needs to change; PythonClass stays the same.
#
# Sequence:
#   1. Robocopy the AMI's Python311 to a sibling dir
#      (Python311-bindings-rs).
#   2. pip-install the four bindings-rs wheels into the new tree
#      using its own python.exe; smoke-test `import openjd.model`
#      from that interpreter. If the smoke test fails, throw before
#      touching the registry -- the running service stays untouched.
#   3. Drop a marker file (bindings-rs-installed) so the host-config
#      run that the new agent process will trigger on startup is a
#      no-op.
#   4. Spawn a detached, hidden PowerShell child. The child:
#        a. waits 3 seconds,
#        b. rewrites ImagePath to the new pythonservice.exe,
#        c. force-kills the running pythonservice.exe with
#           Stop-Process -Force (NOT Stop-Service -- that would
#           trigger UpdateWorker(STOPPED) and end the spot lease),
#        d. waits for SCM to mark the service Stopped, then either
#           lets SCM auto-recovery start it or calls Start-Service
#           explicitly.
#   5. The host-config script then blocks in `Start-Sleep -Seconds 60`.
#      The child's force-kill terminates the host-config script as
#      a side effect (it runs as a child of the same pythonservice.exe).
#      Because the script never returns 0 to the agent, the agent
#      never records host_configuration_succeeded=True and never
#      enters the session loop -- so it can't pick up a job that
#      would be left in an inconsistent state when the kill fires.
#      After the new pythonservice.exe starts up, the new agent
#      runs host-config again, hits the marker file, exits 0
#      cleanly, and only THEN enters the session loop.

Write-Host "Running Host Configuration script (parallel install of bindings-rs build)."
_DLog "After Write-Host (start)"

$markerFile = "C:\ProgramData\Amazon\Deadline\bindings-rs-installed"
if (Test-Path $markerFile) {
    Write-Host "Marker present -- bindings-rs install already applied. Exiting."
    _DLog "Marker present, exiting 0"
    exit 0
}
_DLog "Marker not present, proceeding with install"

# --- Resolve the source Python (the one the service currently runs) ---
function Get-DeadlineWorkerPython {
    $smfPython = 'C:\Program Files\Python311\python.exe'
    if (Test-Path $smfPython) { return $smfPython }
    $svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\DeadlineWorker'
    $imagePath = (Get-ItemProperty -Path $svcKey -Name ImagePath -ErrorAction Stop).ImagePath
    $exePath = ($imagePath -replace '^"([^"]+)".*', '$1')
    $exeDir = Split-Path $exePath -Parent
    $sibling = Join-Path $exeDir 'python.exe'
    if (Test-Path $sibling) { return $sibling }
    throw "Could not locate DeadlineWorker python.exe (ImagePath='$imagePath')"
}

$srcPy = Get-DeadlineWorkerPython
$srcRoot = Split-Path $srcPy -Parent
$dstRoot = Join-Path (Split-Path $srcRoot -Parent) ((Split-Path $srcRoot -Leaf) + '-bindings-rs')
$dstPy = Join-Path $dstRoot 'python.exe'
$dstSvcExe = Join-Path $dstRoot 'pythonservice.exe'

Write-Host "Source Python : $srcPy"
Write-Host "Source root   : $srcRoot"
Write-Host "Target root   : $dstRoot"

# --- Robocopy the source Python tree to a sibling directory ---
# /MIR mirrors; /XJ skips junctions; /R:1 /W:1 keeps retries cheap;
# /NP /NFL /NDL trims output to file-counts only.
if (Test-Path $dstRoot) {
    Write-Host "Removing previous parallel install at $dstRoot"
    Remove-Item -Recurse -Force $dstRoot
}
Write-Host "Copying $srcRoot -> $dstRoot ..."
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & robocopy $srcRoot $dstRoot /MIR /XJ /R:1 /W:1 /NP /NFL /NDL | Out-Null
    # Robocopy uses non-zero exit codes for SUCCESS too -- anything <=7 is OK.
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }
} finally {
    $ErrorActionPreference = $prev
}
if (-not (Test-Path $dstPy))     { throw "Missing python.exe at $dstPy after robocopy" }
if (-not (Test-Path $dstSvcExe)) { throw "Missing pythonservice.exe at $dstSvcExe after robocopy" }
Write-Host "Robocopy complete."

# --- Download wheels from S3 ---
$tempDir = "C:\temp\deadline-wheels"
if (-not (Test-Path $tempDir)) {
    New-Item -Path $tempDir -ItemType Directory | Out-Null
}
foreach ($whl in @($MODEL_WHL, $SESSIONS_WHL, $AGENT_WHL, $DEADLINE_WHL)) {
    Write-Host "Downloading $whl from s3://$S3_BUCKET/$S3_PREFIX/$whl"
    aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$whl" "$tempDir\"
}

# --- Install wheels into the parallel install ---
function Invoke-Pip {
    param([Parameter(Mandatory)][string]$Wheel)
    Write-Host "Installing $Wheel into $dstPy"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $dstPy -m pip install $Wheel --force-reinstall --no-deps 2>&1 | ForEach-Object { Write-Host $_ }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($LASTEXITCODE -ne 0) {
        throw "pip install $Wheel failed with exit code $LASTEXITCODE"
    }
}

Invoke-Pip "$tempDir\$MODEL_WHL"
Invoke-Pip "$tempDir\$SESSIONS_WHL"
Invoke-Pip "$tempDir\$AGENT_WHL"
Invoke-Pip "$tempDir\$DEADLINE_WHL"

Write-Host "Installed packages in parallel install:"
$ErrorActionPreference = 'Continue'
(& $dstPy -m pip list 2>&1) | Select-String -Pattern "openjd|deadline"
$ErrorActionPreference = 'Stop'

# Quick smoke test: ensure the installed openjd.model imports cleanly
# in the new interpreter. If this fails, don't repoint the service.
Write-Host "Smoke-testing imports in the new interpreter..."
$ErrorActionPreference = 'Continue'
$smoke = & $dstPy -c "import openjd.model; from openjd.model._version import __version__; print('OK', __version__)" 2>&1
$smokeRc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Write-Host "Smoke test: $smoke"
if ($smokeRc -ne 0) {
    throw "Smoke test failed with exit code $smokeRc -- refusing to repoint the service."
}

# --- Mark success BEFORE the service swap ---
# The detached child below will stop and restart the service; that
# kills *this* script process (we run as a child of the live service).
# Drop the marker now so a re-run after any future host-config trigger
# is a no-op.
New-Item $markerFile -ItemType File -Force | Out-Null

# --- Hand off to a detached child to swap and restart the service ---
#
# We can't restart our own service from inside it. Spawn a hidden,
# detached powershell that:
#   1. waits ~3s so we (the running host-config script) are still
#      sitting in our heartbeat sleep loop -- the agent has not yet
#      seen us return 0 and has not entered the session-poll loop;
#   2. rewrites ImagePath in the registry to point at the parallel
#      install's pythonservice.exe -- SCM only reads ImagePath on the
#      next StartService call, so this doesn't touch the running
#      process;
#   3. calls Restart-Service -Force, which delivers SERVICE_CONTROL_STOP
#      via SCM. That fires the agent's SvcStop callback, which sets
#      _stop_event and lets the agent exit through its normal
#      shutdown path -- including UpdateWorker(STOPPED). This matches
#      the Linux flow exactly: `systemctl restart` sends SIGTERM,
#      the agent's SIGTERM handler calls UpdateWorker(STOPPED), the
#      new agent comes up <1s later, re-registers under the same
#      worker_id from Cache\worker.json, and resumes heartbeats
#      before Deadline's autoscaling reconciler reacts.
#   4. SCM then starts a fresh pythonservice.exe using the new
#      ImagePath. The new agent re-runs host-config (this script),
#      sees the marker file we dropped before spawning this child,
#      short-circuits with exit 0. Agent enters job loop with the
#      bindings-rs build.
#
# Why NOT Stop-Process -Force on pythonservice.exe: that is SIGKILL,
# not SIGTERM. SvcStop is an SCM callback (not an OS signal handler),
# so it isn't fired on a force-kill. Without SvcStop, the agent
# never calls UpdateWorker(STOPPED), and the server-side state
# machine is left wedged in STARTED. The new agent can't transition
# STARTED -> IDLE because Deadline still thinks the prior agent is
# alive. We empirically saw workers stuck in STARTED for 5+ minutes
# under that path. Restart-Service avoids it.
$dstSvcExeQuoted = '"' + $dstSvcExe + '"'

$childScript = @"
`$ErrorActionPreference = 'Continue'
`$debugLog = '$debugLog'
function _CLog { param(`$m) "`$(Get-Date -Format o)  [child]  `$m" | Out-File -FilePath `$debugLog -Encoding utf8 -Append }
_CLog 'child started; sleeping 3s before swap'
Start-Sleep -Seconds 3

try {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DeadlineWorker' ``
        -Name ImagePath -Value '$dstSvcExeQuoted'
    _CLog "ImagePath rewritten to $dstSvcExeQuoted"
} catch {
    _CLog "Set-ItemProperty failed: `$_"
}

# Restart-Service -Force is the canonical Windows equivalent of
# `systemctl restart`. SCM sends SERVICE_CONTROL_STOP -> the agent's
# SvcStop fires -> agent calls UpdateWorker(STOPPED) and exits cleanly
# -> SCM then calls StartService with the new ImagePath. -Force
# bypasses dependent-service prompts; we have no dependents here.
try {
    Restart-Service -Name DeadlineWorker -Force
    _CLog 'Restart-Service returned'
} catch {
    _CLog "Restart-Service failed: `$_"
}

`$svc = Get-Service DeadlineWorker
for (`$i = 0; `$i -lt 30; `$i++) {
    `$svc.Refresh()
    if (`$svc.Status -eq 'Running') { break }
    Start-Sleep -Seconds 1
}
_CLog "SCM service status after restart (loop end): `$(`$svc.Status)"
_CLog 'child done'
"@
$childScriptPath = Join-Path $env:TEMP 'deadline-bindings-rs-swap.ps1'
Set-Content -Path $childScriptPath -Value $childScript -Encoding UTF8

Write-Host "Spawning detached service-swap child: $childScriptPath"
Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $childScriptPath) `
    -WindowStyle Hidden

# Block here long enough for the detached child to wake up and kill
# our service. While we're in this sleep, the agent has not yet
# returned from running host config -- so it has not entered the
# session loop, has not picked up any jobs, and will not have any
# in-flight session state when it dies. The kill ends this sleep
# before it completes; we should never reach the lines below.
#
# Emit a heartbeat every second so the CloudWatch log shows exactly
# when the kill fires (last heartbeat second-mark) -- the gap between
# the last heartbeat and the post-swap "host config short-circuit by
# marker" lets us measure swap latency and confirm the kill worked.
Write-Host "Sleeping up to 60s; detached child will kill the service before this returns."
for ($i = 1; $i -le 60; $i++) {
    Write-Host ("heartbeat {0:D2}/60 (waiting for kill)" -f $i)
    Start-Sleep -Seconds 1
}

# If we ever DO reach here, something has gone wrong with the kill.
# Exit non-zero so Deadline knows the host config failed and the
# new service won't start without intervention.
Write-Host "ERROR: host-config script slept past kill window. Detached child failed to fire."
exit 2
