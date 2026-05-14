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

# Parallel-install strategy (Windows SMF). See
# docs/testing-worker-agent-on-smf.md for the rationale; in brief:
#   - Robocopy the AMI's Python311 to a sibling dir
#   - pip-install bindings-rs wheels into the copy
#   - Drop a marker file so the post-restart host-config invocation
#     is a no-op
#   - Spawn a detached child that calls UpdateWorker(STOPPED) via
#     AWS CLI, rewrites the SCM ImagePath, and force-kills
#     pythonservice.exe
#   - The host-config script sleeps until the kill; never returns 0,
#     so the agent never enters the session loop with the old code

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
$dstSvcExeQuoted = '"' + $dstSvcExe + '"'

$childScript = @"
`$ErrorActionPreference = 'Continue'
`$debugLog = '$debugLog'
function _CLog { param(`$m) "`$(Get-Date -Format o)  [child]  `$m" | Out-File -FilePath `$debugLog -Encoding utf8 -Append }
_CLog 'child started; sleeping 3s before swap'
Start-Sleep -Seconds 3

# Sequence: UpdateWorker(STOPPED) via AWS CLI, then ImagePath
# rewrite, then force-kill pythonservice.exe, then Start-Service
# brings up the new pythonservice.exe. We can't use Stop-Service
# from here -- SCM's SERVICE_CONTROL_STOP would fire SvcStop in the
# agent, but the agent's main thread is busy running this script,
# so SvcStop can't be observed and Stop-Service deadlocks.
try {
    `$svc0 = Get-Service DeadlineWorker -ErrorAction Stop
    _CLog "pre-swap service status: `$(`$svc0.Status)"
} catch {
    _CLog "Get-Service pre-check failed: `$_"
}

# 1. Tell Deadline the worker is going down.
_CLog 'calling UpdateWorker(STOPPED)'
try {
    `$awsArgs = @(
        'deadline', 'update-worker',
        '--farm-id', `$env:DEADLINE_FARM_ID,
        '--fleet-id', `$env:DEADLINE_FLEET_ID,
        '--worker-id', `$env:DEADLINE_WORKER_ID,
        '--status', 'STOPPED',
        '--region', `$env:AWS_DEFAULT_REGION
    )
    `$out = & aws @awsArgs 2>&1
    _CLog "UpdateWorker rc=`$LASTEXITCODE output=`$out"
} catch {
    _CLog "UpdateWorker call failed: `$_"
}

# 2. Rewrite the ImagePath.
try {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DeadlineWorker' ``
        -Name ImagePath -Value '$dstSvcExeQuoted'
    _CLog "ImagePath rewritten to $dstSvcExeQuoted"
} catch {
    _CLog "Set-ItemProperty failed: `$_"
}

# 3. Force-kill pythonservice.exe. This kills our parent (the
#    host-config script will be terminated mid-heartbeat).
try {
    `$svcPid = (Get-CimInstance Win32_Service -Filter "Name='DeadlineWorker'").ProcessId
    _CLog "DeadlineWorker PID: `$svcPid"
    if (`$svcPid -and `$svcPid -ne 0) {
        Stop-Process -Id `$svcPid -Force -ErrorAction Stop
        _CLog "force-killed PID `$svcPid"
    }
} catch {
    _CLog "Stop-Process failed: `$_"
}

# 4. Wait for SCM, then start the new service.
`$svc = Get-Service DeadlineWorker
for (`$i = 0; `$i -lt 30; `$i++) {
    `$svc.Refresh()
    if (`$svc.Status -eq 'Stopped') { break }
    Start-Sleep -Seconds 1
}
_CLog "SCM service status after kill: `$(`$svc.Status)"

if (`$svc.Status -ne 'Running') {
    try {
        Start-Service -Name DeadlineWorker -ErrorAction Stop
        Start-Sleep -Seconds 2
        `$svc.Refresh()
        _CLog "Start-Service returned; status now `$(`$svc.Status)"
    } catch {
        _CLog "Start-Service failed: `$_"
    }
} else {
    _CLog 'service already Running (auto-recovery); nothing to do'
}
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
