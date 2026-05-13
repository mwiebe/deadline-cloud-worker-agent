$ErrorActionPreference = "Stop"

$S3_BUCKET = "__S3_BUCKET__"
$S3_PREFIX = "__S3_PREFIX__"
$MODEL_WHL = "__MODEL_WHL__"
$SESSIONS_WHL = "__SESSIONS_WHL__"
$AGENT_WHL = "__AGENT_WHL__"
$DEADLINE_WHL = "__DEADLINE_WHL__"

Write-Host "Running Host Configuration script to install Rust-backed openjd libraries."

$markerFile = "C:\ProgramData\Amazon\Deadline\rebooted"
if (Test-Path $markerFile) {
    Write-Host "Host already rebooted, ready to start."
    exit 0
}
Write-Host "Host has not been rebooted."

# Resolve the python.exe used by the DeadlineWorker service so the wheel
# install lands in the same interpreter the service imports from.
#
# The Windows SMF AMI installs the agent into the system Python at
# C:\Program Files\Python311 (no per-worker venv) and registers the
# Windows service via pywin32, so the service's ImagePath is the
# pywin32 host binary `pythonservice.exe` next to that python.exe.
# Custom Windows agent installs may instead use a venv layout
# (`<venv>\Scripts\python.exe` or `<venv>\bin\python.exe`).
function Get-DeadlineWorkerPython {
    # Primary: SMF AMI system-Python install.
    $smfPython = 'C:\Program Files\Python311\python.exe'
    if (Test-Path $smfPython) { return $smfPython }

    # Fallback: derive from the service's ImagePath. ImagePath looks like:
    #   "<dir>\pythonservice.exe"  (SMF / pywin32 install)
    #   "<venv>\Scripts\DeadlineWorkerService.exe" -classname=...  (custom venv)
    $svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\DeadlineWorker'
    $imagePath = (Get-ItemProperty -Path $svcKey -Name ImagePath -ErrorAction Stop).ImagePath
    $exePath = ($imagePath -replace '^"([^"]+)".*', '$1')
    $exeDir = Split-Path $exePath -Parent

    # 1. python.exe in the same directory (SMF / pywin32 layout)
    $sibling = Join-Path $exeDir 'python.exe'
    if (Test-Path $sibling) { return $sibling }

    # 2. python.exe under the venv root (custom-venv layout)
    $venvRoot = Split-Path $exeDir -Parent
    foreach ($sub in @('Scripts\python.exe', 'bin\python.exe')) {
        $candidate = Join-Path $venvRoot $sub
        if (Test-Path $candidate) { return $candidate }
    }

    throw "Could not locate DeadlineWorker python.exe (ImagePath='$imagePath')"
}

$py = Get-DeadlineWorkerPython
Write-Host "Using Python: $py"

$tempDir = "C:\temp\deadline-wheels"
if (-not (Test-Path $tempDir)) {
    New-Item -Path $tempDir -ItemType Directory | Out-Null
}

foreach ($whl in @($MODEL_WHL, $SESSIONS_WHL, $AGENT_WHL, $DEADLINE_WHL)) {
    Write-Host "Downloading $whl from s3://$S3_BUCKET/$S3_PREFIX/$whl"
    aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$whl" "$tempDir\"
}

& $py -m pip install "$tempDir\$MODEL_WHL" --force-reinstall --no-deps
& $py -m pip install "$tempDir\$SESSIONS_WHL" --force-reinstall --no-deps
& $py -m pip install "$tempDir\$AGENT_WHL" --force-reinstall --no-deps
& $py -m pip install "$tempDir\$DEADLINE_WHL" --force-reinstall --no-deps

Write-Host "Installed packages:"
& $py -m pip list | Select-String -Pattern "openjd|deadline"

New-Item $markerFile -ItemType File -Force | Out-Null
Write-Host "Marker file created, rebooting worker host."
Restart-Computer -Force
Start-Sleep 60
exit 1
