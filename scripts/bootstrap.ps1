[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
function Assert-NativeSuccess([string]$Step) {
  if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE." }
}
$projectRoot = Split-Path $PSScriptRoot -Parent
$cacheRoot = Join-Path $projectRoot ".cache"
$venvPath = Join-Path $projectRoot ".venv"
$taskTemp = Join-Path $projectRoot ".tmp"
$env:PIP_CACHE_DIR = Join-Path $cacheRoot "pip"
$env:npm_config_cache = Join-Path $cacheRoot "npm"
$env:TEMP = $taskTemp
$env:TMP = $taskTemp
$npm = Get-Command npm.cmd -ErrorAction Stop

New-Item -ItemType Directory -Path $env:PIP_CACHE_DIR, $env:npm_config_cache, $taskTemp -Force | Out-Null

Push-Location (Join-Path $projectRoot "apps\web")
try {
  & $npm.Source ci --no-audit --no-fund
  Assert-NativeSuccess "React/Vinext npm install"
} finally {
  Pop-Location
}

if (-not (Test-Path -LiteralPath $venvPath)) {
  $pythonLauncher = Get-Command py -ErrorAction SilentlyContinue
  $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
  if ($pythonLauncher) {
    & $pythonLauncher.Source -3.12 -m venv $venvPath
    Assert-NativeSuccess "Python virtual environment creation"
  } elseif ($pythonCommand) {
    & $pythonCommand.Source -m venv $venvPath
    Assert-NativeSuccess "Python virtual environment creation"
  } else {
    throw "Python 3.12 or newer is required. Install Python, then run this script again."
  }
}

$python = Join-Path $venvPath "Scripts\python.exe"
& $python -m pip install --upgrade pip
Assert-NativeSuccess "pip upgrade"
& $python -m pip install -e "$(Join-Path $projectRoot 'services\api')[dev]" -e "$(Join-Path $projectRoot 'services\ml')[dev]" -e "$(Join-Path $projectRoot 'services\edge')[dev]"
Assert-NativeSuccess "FingerSpeak Python dependency installation"

Write-Host "FingerSpeak dependencies are installed under $projectRoot"
