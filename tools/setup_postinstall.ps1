# Bakushi post-install step.
# Runs ONCE after setup (from the installer, with -ExecutionPolicy Bypass).
# ASCII only - Windows PowerShell 5.1 parses BOM-less UTF-8 as ANSI.
#
# 1. Locate Python 3.11 (py launcher / PATH / known install dirs).
# 2. If missing: silently run the bundled python.org installer.
# 3. pip install the sidecar requirements.
# 4. Self-test the sidecar against the bundled model.
# 5. Pre-write the model path into bakushi_settings.json (merge, never
#    overwrite other keys) so the first app launch skips the picker.
param([Parameter(Mandatory = $true)][string]$AppDir)

$ErrorActionPreference = 'Stop'

$modelPath = Join-Path $AppDir 'assets\models\htdemucs_fp16weights.onnx'
$requirements = Join-Path $AppDir 'sidecar\requirements.txt'
$sidecar = Join-Path $AppDir 'sidecar\bakushi_sidecar.py'
$pythonInstaller = Join-Path $AppDir 'redist\python-3.11.9-amd64.exe'
$pipLog = Join-Path $AppDir 'postinstall_pip.log'
$selftestLog = Join-Path $AppDir 'postinstall_selftest.log'

function Refresh-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Find-Python311 {
    # Known per-user / per-machine install locations.
    $known = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        (Join-Path $env:ProgramFiles 'Python311\python.exe')
    )
    foreach ($candidate in $known) {
        if (Test-Path $candidate) { return $candidate }
    }
    # python on PATH with the right version.
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) {
        $v = & $cmd.Source -c "import sys; print(sys.version_info[0], sys.version_info[1])" 2>$null
        if ($LASTEXITCODE -eq 0 -and ("$v" -match '3\s*11')) { return $cmd.Source }
    }
    # py launcher.
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        $exe = & $py.Source -3.11 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe) {
            return ($exe | Select-Object -First 1).Trim()
        }
    }
    return $null
}

function Fail([string]$message) {
    Write-Host "BAKUSHI POSTINSTALL FAILED: $message"
    exit 1
}

Refresh-PathFromRegistry
$python = Find-Python311

if (-not $python) {
    Write-Host 'Bakushi setup: Python 3.11 not found - running the bundled installer.'
    if (-not (Test-Path $pythonInstaller)) {
        Fail "bundled python installer is missing: $pythonInstaller"
    }
    $p = Start-Process -FilePath $pythonInstaller `
        -ArgumentList '/quiet InstallAllUsers=0 PrependPath=1 Include_pip=1' `
        -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Fail "python installer exited with code $($p.ExitCode)"
    }
    Refresh-PathFromRegistry
    $python = Find-Python311
}

if (-not $python) {
    Fail 'could not locate Python 3.11 after installing it'
}
Write-Host "Bakushi setup: using $python"

& $python -m pip install -r $requirements *> $pipLog
if ($LASTEXITCODE -ne 0) {
    Fail "pip install failed (log: $pipLog)"
}

& $python $sidecar --selftest --model $modelPath *> $selftestLog
if ($LASTEXITCODE -ne 0) {
    Fail "sidecar selftest failed (log: $selftestLog)"
}

# Pre-write the model path (merge, keep every other key).
$settingsDir = Join-Path $env:APPDATA 'com.bakushi\bakushi'
New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
$settingsFile = Join-Path $settingsDir 'bakushi_settings.json'
$obj = $null
if (Test-Path $settingsFile) {
    try {
        $obj = Get-Content $settingsFile -Raw | ConvertFrom-Json
    } catch {
        $obj = $null
    }
}
if ($obj -isnot [System.Management.Automation.PSCustomObject]) {
    $obj = New-Object PSObject
}
$obj | Add-Member -NotePropertyName model_path -NotePropertyValue $modelPath -Force
$json = $obj | ConvertTo-Json
# UTF-8 WITHOUT BOM (Dart jsonDecode chokes on a BOM).
[System.IO.File]::WriteAllText(
    $settingsFile,
    $json,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host 'Bakushi setup: post-install complete.'
exit 0
