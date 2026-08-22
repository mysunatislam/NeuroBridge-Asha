[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
function Assert-NativeSuccess([string]$Step) {
  if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE." }
}
$projectRoot = Split-Path $PSScriptRoot -Parent
$python = Join-Path $projectRoot ".venv\Scripts\python.exe"
$taskTemp = Join-Path $projectRoot ".tmp"
$env:TEMP = $taskTemp
$env:TMP = $taskTemp
$npm = Get-Command npm.cmd -ErrorAction Stop
$node = Get-Command node.exe -ErrorAction Stop
New-Item -ItemType Directory -Path $taskTemp -Force | Out-Null

if (-not (Test-Path -LiteralPath $python)) {
  throw "Run scripts\bootstrap.ps1 first."
}

Push-Location (Join-Path $projectRoot "apps\web")
try {
  & $npm.Source run typecheck
  Assert-NativeSuccess "React/Vinext frontend typecheck"
  & $npm.Source run lint
  Assert-NativeSuccess "React/Vinext frontend lint"
  & $npm.Source run test
  Assert-NativeSuccess "React/Vinext core tests"
  & $npm.Source run build
  Assert-NativeSuccess "React/Vinext production build"
  & $node.Source --test tests/rendered-html.test.mjs
  Assert-NativeSuccess "React/Vinext rendered worker tests"
} finally {
  Pop-Location
}

& $python -m pytest -q --basetemp (Join-Path $taskTemp "pytest-api") (Join-Path $projectRoot "services\api\tests")
Assert-NativeSuccess "API tests"
& $python -m pytest -q --basetemp (Join-Path $taskTemp "pytest-ml") (Join-Path $projectRoot "services\ml\tests")
Assert-NativeSuccess "ML tests"
& $python -m pytest -q --basetemp (Join-Path $taskTemp "pytest-edge") (Join-Path $projectRoot "services\edge\tests")
Assert-NativeSuccess "Raspberry Pi edge tests"
& $python -m ruff check (Join-Path $projectRoot "services\api") (Join-Path $projectRoot "services\ml") (Join-Path $projectRoot "services\edge")
Assert-NativeSuccess "Python lint"
& $python -m compileall -q (Join-Path $projectRoot "services\api\src") (Join-Path $projectRoot "services\ml\src") (Join-Path $projectRoot "services\edge\src")
Assert-NativeSuccess "Python source compilation"

$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($docker) {
  & $docker.Source compose -f (Join-Path $projectRoot "infra\compose.yaml") config --quiet
  Assert-NativeSuccess "Compose configuration"
} else {
  Write-Warning "Docker is not installed; Compose runtime validation was skipped."
}
