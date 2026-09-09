# scripts/deploy_live.ps1
# Builds the production web app and deploys to the public NeuroBridge-Asha-live repository.

$ErrorActionPreference = "Stop"
Write-Host "==> Building NeuroBridge Asha Flutter Web App for Live Deployment..." -ForegroundColor Cyan
Set-Location "$PSScriptRoot\..\apps\mobile"

flutter build web --no-wasm-dry-run --tree-shake-icons --optimization-level 4 --base-href "/NeuroBridge-Asha-live/"

Write-Host "==> Mirroring web assets..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path "build/web/assets/web" | Out-Null
Copy-Item -Path "build/web/assets/assets/web/*" -Destination "build/web/assets/web/" -Recurse -Force
Copy-Item -Path "build/web/index.html" -Destination "build/web/404.html" -Force
New-Item -ItemType File -Path "build/web/.nojekyll" -Force | Out-Null

Set-Location "build/web"
$token = gh auth token
if (-not (Test-Path ".git")) {
    git init
    git checkout -b main
    git config user.name "Mysunat Islam"
    git config user.email "mysunatislam@gmail.com"
}
git remote remove origin 2>$null
git remote add origin "https://x-access-token:$token@github.com/mysunatislam/NeuroBridge-Asha-live.git"
git add .
git commit -m "Deploy NeuroBridge Asha live web application"
git push -u origin main --force

Write-Host "==> Successfully deployed to https://mysunatislam.github.io/NeuroBridge-Asha-live/" -ForegroundColor Green
