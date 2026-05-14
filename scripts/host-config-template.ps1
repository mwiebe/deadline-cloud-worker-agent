# Side debug log on disk; see docs/testing-worker-agent-on-smf.md.
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

$ErrorActionPreference = "Continue"

$S3_BUCKET = "__S3_BUCKET__"
$S3_PREFIX = "__S3_PREFIX__"
$DEBUG_S3_PREFIX = "DeadlineCloud/bindings-rs-debug"
$MODEL_WHL = "__MODEL_WHL__"
$SESSIONS_WHL = "__SESSIONS_WHL__"
$AGENT_WHL = "__AGENT_WHL__"
$DEADLINE_WHL = "__DEADLINE_WHL__"

Write-Host "Running Host Configuration script (parallel install of bindings-rs build)."
_DLog "After Write-Host (start)"

$markerFile = "C:\ProgramData\Amazon\Deadline\bindings-rs-installed"
if (Test-Path $markerFile) {
    Write-Host "Marker present -- bindings-rs install already applied. Exiting."
    _DLog "Marker present, exiting 0"
    exit 0
}
_DLog "Marker not present, proceeding with install"

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

$origImagePath = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DeadlineWorker' -Name ImagePath).ImagePath
_DLog "Original ImagePath: $origImagePath"

Write-Host "Source Python : $srcPy"
Write-Host "Source root   : $srcRoot"
Write-Host "Target root   : $dstRoot"

if (Test-Path $dstRoot) {
    Write-Host "Removing previous parallel install at $dstRoot"
    Remove-Item -Recurse -Force $dstRoot
}
Write-Host "Copying $srcRoot -> $dstRoot ..."
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & robocopy $srcRoot $dstRoot /MIR /XJ /R:1 /W:1 /NP /NFL /NDL | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }
} finally {
    $ErrorActionPreference = $prev
}
if (-not (Test-Path $dstPy))     { throw "Missing python.exe at $dstPy after robocopy" }
if (-not (Test-Path $dstSvcExe)) { throw "Missing pythonservice.exe at $dstSvcExe after robocopy" }
Write-Host "Robocopy complete."

$tempDir = "C:\temp\deadline-wheels"
if (-not (Test-Path $tempDir)) {
    New-Item -Path $tempDir -ItemType Directory | Out-Null
}
foreach ($whl in @($MODEL_WHL, $SESSIONS_WHL, $AGENT_WHL, $DEADLINE_WHL)) {
    Write-Host "Downloading $whl from s3://$S3_BUCKET/$S3_PREFIX/$whl"
    aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$whl" "$tempDir\"
}

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

Write-Host "Smoke-testing imports in the new interpreter..."
$ErrorActionPreference = 'Continue'
$smoke = & $dstPy -c "import openjd.model; from openjd.model._version import __version__; print('OK', __version__)" 2>&1
$smokeRc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Write-Host "Smoke test: $smoke"
if ($smokeRc -ne 0) {
    throw "Smoke test failed with exit code $smokeRc -- refusing to repoint the service."
}

New-Item $markerFile -ItemType File -Force | Out-Null

$instanceId = ""
try {
    $token = (Invoke-RestMethod -Method PUT -Uri "http://169.254.169.254/latest/api/token" `
        -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="300"} -TimeoutSec 5)
    $instanceId = (Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/instance-id" `
        -Headers @{"X-aws-ec2-metadata-token"=$token} -TimeoutSec 5)
} catch {
    $instanceId = "unknown-$([guid]::NewGuid().ToString().Substring(0,8))"
}
$debugS3Key = "$DEBUG_S3_PREFIX/$instanceId.log"
_DLog "Debug-log watchdog will upload to s3://$S3_BUCKET/$debugS3Key"

$watchdogScript = @"
`$ErrorActionPreference = 'Continue'
`$debugLog = '$debugLog'
`$bucket   = '$S3_BUCKET'
`$key      = '$debugS3Key'
for (`$i = 0; `$i -lt 60; `$i++) {
    Start-Sleep -Seconds 10
    if (Test-Path `$debugLog) {
        try {
            & aws s3 cp `$debugLog "s3://`$bucket/`$key" --quiet 2>&1 | Out-Null
        } catch { }
    }
}
"@
$watchdogPath = Join-Path $env:TEMP 'deadline-bindings-rs-watchdog.ps1'
Set-Content -Path $watchdogPath -Value $watchdogScript -Encoding UTF8
Write-Host "Spawning detached watchdog: $watchdogPath"
Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $watchdogPath) `
    -WindowStyle Hidden

# Replace exe portion of ImagePath, keep any trailing args.
if ($origImagePath -match '^"([^"]+)"(.*)$') {
    $imagePathValue = '"' + $dstSvcExe + '"' + $Matches[2]
} elseif ($origImagePath -match '^([^ ]+)(.*)$') {
    $imagePathValue = '"' + $dstSvcExe + '"' + $Matches[2]
} else {
    $imagePathValue = '"' + $dstSvcExe + '"'
}
_DLog "New ImagePath will be: $imagePathValue"

$childScript = @"
`$ErrorActionPreference = 'Continue'
`$debugLog = '$debugLog'
`$bucket   = '$S3_BUCKET'
`$debugKey = '$debugS3Key'
function _CLog { param(`$m) "`$(Get-Date -Format o)  [child]  `$m" | Out-File -FilePath `$debugLog -Encoding utf8 -Append }
function _UploadLog {
    if (Test-Path `$debugLog) {
        try { & aws s3 cp `$debugLog "s3://`$bucket/`$debugKey" --quiet 2>&1 | Out-Null } catch { }
    }
}
_CLog 'child started; sleeping 3s before swap'
_UploadLog
Start-Sleep -Seconds 3

try {
    `$svc0 = Get-Service DeadlineWorker -ErrorAction Stop
    _CLog "pre-swap service status: `$(`$svc0.Status)"
} catch {
    _CLog "Get-Service pre-check failed: `$_"
}

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

`$newImagePath = '$imagePathValue'
try {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DeadlineWorker' ``
        -Name ImagePath -Value `$newImagePath
    _CLog "ImagePath rewritten to `$newImagePath"
} catch {
    _CLog "Set-ItemProperty failed: `$_"
}

_UploadLog
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

# Diagnostic snapshot written to a separate file, uploaded once.
`$diagPath = 'C:\ProgramData\Amazon\Deadline\bindings-rs-diag.log'
`$diagKey  = '$DEBUG_S3_PREFIX/$instanceId' + '-diag.log'
function _DiagLog { param(`$m) "`$(Get-Date -Format o)  `$m" | Out-File -FilePath `$diagPath -Encoding utf8 -Append }
try {
    _DiagLog "=== diag start; svc.Status=`$(`$svc.Status)"
    try { `$cim = Get-CimInstance Win32_Service -Filter "Name='DeadlineWorker'"; _DiagLog "CIM Path=`$(`$cim.PathName) State=`$(`$cim.State) Exit=`$(`$cim.ExitCode) StartName=`$(`$cim.StartName)" } catch { _DiagLog "CIM fail: `$_" }
    try {
        `$evts = Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Service Control Manager'} -MaxEvents 25 -ErrorAction Stop | Where-Object { `$_.Message -like '*DeadlineWorker*' } | Select-Object -First 10
        foreach (`$e in `$evts) { _DiagLog "scm `$(`$e.TimeCreated.ToString('s')) [`$(`$e.Id)] `$((`$e.Message -split '\r?\n')[0])" }
    } catch { _DiagLog "scm fail: `$_" }
    try {
        `$evts2 = Get-WinEvent -FilterHashtable @{LogName='Application';MaxEvents=50} -ErrorAction Stop | Where-Object { `$_.Message -like '*DeadlineWorker*' -or `$_.Message -like '*pythonservice*' -or `$_.Message -like '*WorkerAgent*' } | Select-Object -First 10
        foreach (`$e in `$evts2) { _DiagLog "app `$(`$e.TimeCreated.ToString('s')) [`$(`$e.ProviderName) `$(`$e.Id)] `$((`$e.Message -split '\r?\n')[0])" }
    } catch { _DiagLog "app fail: `$_" }
    try {
        `$svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\DeadlineWorker'
        Get-ChildItem `$svcKey -Recurse | ForEach-Object { _DiagLog "reg subkey `$(`$_.Name)" }
        if (Test-Path "`$svcKey\PythonClass") {
            (Get-ItemProperty "`$svcKey\PythonClass").PSObject.Properties | Where-Object { `$_.Name -notmatch '^PS' } | ForEach-Object { _DiagLog "reg PythonClass.`$(`$_.Name)=`$(`$_.Value)" }
        }
        if (Test-Path "`$svcKey\Parameters") {
            (Get-ItemProperty "`$svcKey\Parameters").PSObject.Properties | Where-Object { `$_.Name -notmatch '^PS' } | ForEach-Object { _DiagLog "reg Parameters.`$(`$_.Name)=`$(`$_.Value)" }
        }
    } catch { _DiagLog "reg fail: `$_" }
    try {
        # Run pythonservice in console-debug mode to expose any Python
        # traceback the SCM normally swallows. Time-bound it with a
        # background job so a hang doesn't block the whole diag.
        `$dbgJob = Start-Job -ScriptBlock { param(`$exe) & `$exe -debug DeadlineWorker 2>&1 | Out-String } -ArgumentList '$dstSvcExe'
        if (Wait-Job `$dbgJob -Timeout 12) {
            `$dbgOut = Receive-Job `$dbgJob 2>&1
            (`$dbgOut -split '\r?\n') | Select-Object -First 40 | ForEach-Object { _DiagLog "svc-debug: `$_" }
        } else {
            Stop-Job `$dbgJob -ErrorAction SilentlyContinue
            _DiagLog "svc-debug: timed out (likely service entered RUN state)"
            `$dbgOut = Receive-Job `$dbgJob 2>&1
            (`$dbgOut -split '\r?\n') | Select-Object -First 40 | ForEach-Object { _DiagLog "svc-debug-partial: `$_" }
        }
        Remove-Job `$dbgJob -ErrorAction SilentlyContinue
    } catch { _DiagLog "svc-debug fail: `$_" }
    `$logsDir = "`$env:ProgramData\Amazon\Deadline\Logs"
    if (Test-Path `$logsDir) {
        Get-ChildItem `$logsDir -File -ErrorAction SilentlyContinue | ForEach-Object { _DiagLog "agentlog `$(`$_.Name) size=`$(`$_.Length) lastWrite=`$(`$_.LastWriteTime.ToString('s'))" }
        `$bootstrapLog = Join-Path `$logsDir 'worker-agent-bootstrap.log'
        if (Test-Path `$bootstrapLog) {
            try { Get-Content `$bootstrapLog -Tail 50 -Encoding utf8 | ForEach-Object { _DiagLog "bootstrap.log: `$_" } } catch { _DiagLog "bootstrap read fail: `$_" }
        }
    } else { _DiagLog "logsDir missing: `$logsDir" }
    _DiagLog "=== diag end"
} catch { _CLog "diag block hit outer exception: `$_" }

try { & aws s3 cp `$diagPath "s3://`$bucket/`$diagKey" --quiet 2>&1 | Out-Null } catch { }
_CLog "diag uploaded to s3://`$bucket/`$diagKey"

_CLog 'child done'
_UploadLog
"@
$childScriptPath = Join-Path $env:TEMP 'deadline-bindings-rs-swap.ps1'
Set-Content -Path $childScriptPath -Value $childScript -Encoding UTF8

Write-Host "Spawning detached service-swap child: $childScriptPath"
Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $childScriptPath) `
    -WindowStyle Hidden

Write-Host "Sleeping up to 60s; detached child will kill the service before this returns."
for ($i = 1; $i -le 60; $i++) {
    Write-Host ("heartbeat {0:D2}/60 (waiting for kill)" -f $i)
    Start-Sleep -Seconds 1
}
Write-Host "ERROR: host-config script slept past kill window. Detached child failed to fire."
exit 2
