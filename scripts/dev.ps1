[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path $PSScriptRoot -Parent
$composeFile = Join-Path $projectRoot "infra\compose.yaml"
$envFile = Join-Path $projectRoot ".env"
$docker = Get-Command docker -ErrorAction SilentlyContinue

if (-not $docker) {
  throw "Docker Desktop is required for the full React/Vinext + API + PostgreSQL stack. For the offline-capable patient app only, run scripts\bootstrap.ps1, change to apps\web, then run npm.cmd run dev. Run the Raspberry Pi edge simulator separately when hardware telemetry is needed."
}

if (-not (Test-Path -LiteralPath $envFile)) {
  Copy-Item -LiteralPath (Join-Path $projectRoot ".env.example") -Destination $envFile
}

& $docker.Source compose --env-file $envFile -f $composeFile up --build
exit $LASTEXITCODE
