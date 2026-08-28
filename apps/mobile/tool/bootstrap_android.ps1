$ErrorActionPreference = 'Stop'

$flutterCommand = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutterCommand) {
    $userFlutter = Join-Path $env:USERPROFILE 'Development/flutter/bin/flutter.bat'
    if (Test-Path -LiteralPath $userFlutter) {
        $flutterCommand = $userFlutter
    }
}
if (-not $flutterCommand) {
    throw 'Flutter was not found. Install it or add flutter/bin to PATH.'
}

$mobileRoot = Split-Path -Parent $PSScriptRoot
Push-Location $mobileRoot
try {
    if (-not (Test-Path -LiteralPath android/settings.gradle.kts)) {
        & $flutterCommand create --empty --platforms=android --org org.fingerspeak --project-name fingerspeak_mobile .
    }
    Copy-Item -LiteralPath tool/android/AndroidManifest.xml -Destination android/app/src/main/AndroidManifest.xml -Force
    Copy-Item -LiteralPath tool/android/app.build.gradle.kts -Destination android/app/build.gradle.kts -Force
    New-Item -ItemType Directory -Force -Path android/app/src/main/kotlin/org/fingerspeak/mobile | Out-Null
    Copy-Item -LiteralPath tool/android/MainActivity.kt -Destination android/app/src/main/kotlin/org/fingerspeak/mobile/MainActivity.kt -Force
    & $flutterCommand pub get
    & $flutterCommand doctor -v
} finally {
    Pop-Location
}
