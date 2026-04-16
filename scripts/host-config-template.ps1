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

# Activate the worker virtual environment
& "C:\ProgramData\Amazon\Deadline\worker\bin\activate.ps1"

$tempDir = "C:\temp\deadline-wheels"
if (-not (Test-Path $tempDir)) {
    New-Item -Path $tempDir -ItemType Directory | Out-Null
}

foreach ($whl in @($MODEL_WHL, $SESSIONS_WHL, $AGENT_WHL, $DEADLINE_WHL)) {
    Write-Host "Downloading $whl from s3://$S3_BUCKET/$S3_PREFIX/$whl"
    aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$whl" "$tempDir\"
}

pip install "$tempDir\$MODEL_WHL" --force-reinstall --no-deps
pip install "$tempDir\$SESSIONS_WHL" --force-reinstall --no-deps
pip install "$tempDir\$AGENT_WHL" --force-reinstall --no-deps
pip install "$tempDir\$DEADLINE_WHL" --force-reinstall --no-deps

Write-Host "Installed packages:"
pip list | Select-String -Pattern "openjd|deadline"

New-Item $markerFile -ItemType File -Force | Out-Null
Write-Host "Marker file created, rebooting worker host."
Restart-Computer -Force
Start-Sleep 60
exit 1
