<#
    Rebuilds (and optionally installs) the FingerSpeak Android release APK.

    WHY NOT JUST `flutter build apk --release`?
    -------------------------------------------
    On this machine that command aborts before it builds anything:

        Flutter failed to delete a directory at
        "...\apps\mobile\windows\flutter\ephemeral\.plugin_symlinks".
        The flutter tool cannot access the file or directory.

    `flutter pub get` refreshes the ephemeral plugin symlinks for EVERY desktop
    platform in the project (windows/, macos/, linux/), and OneDrive holds locks
    on them. That is a hard ToolExit, so no APK is produced -- but any APK left
    over from an earlier build stays on disk, and `adb install` happily installs
    that stale artifact. That is how a fixed source tree kept reinstalling a
    broken binary.

    `gradlew assembleRelease` only touches the Android host project, so it is
    unaffected. This script:
      1. deletes the previous APK, R8 mapping output and the ART baseline-profile
         intermediates, so a failed build can never masquerade as a good one;
      2. builds through gradlew, retrying once with baseline-profile generation
         disabled if OneDrive locks that output directory;
      3. copies the result to the flutter-apk/ path as well, so installing from
         either location picks up the same, current binary;
      4. reports whether R8 minification ran.

    Pause OneDrive sync before running this. If pubspec.yaml changed, run
    `flutter pub get` once by hand first.

    Usage:
        .\tool\rebuild_android.ps1
        .\tool\rebuild_android.ps1 -Install
        .\tool\rebuild_android.ps1 -Install -Serial 4eb96f00
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$Serial
)

$ErrorActionPreference = 'Stop'

$mobileRoot  = Split-Path -Parent $PSScriptRoot
$androidRoot = Join-Path $mobileRoot 'android'
$gradleApk   = Join-Path $mobileRoot 'build\app\outputs\apk\release\app-release.apk'
$flutterApk  = Join-Path $mobileRoot 'build\app\outputs\flutter-apk\app-release.apk'
$mappingDir  = Join-Path $mobileRoot 'build\app\outputs\mapping\release'
$artProfile  = Join-Path $mobileRoot 'build\app\intermediates\dex_metadata_directory'
$adb         = Join-Path $env:LOCALAPPDATA 'Android\sdk\platform-tools\adb.exe'

# OneDrive and antivirus scanners hold transient handles, so a single delete
# attempt is not enough. Retry briefly before giving up.
function Remove-Stale {
    param([string]$Path, [switch]$Required)

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        if ($attempt -eq 1) { Write-Host "Removing stale $Path" }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        Start-Sleep -Milliseconds (300 * $attempt)
    }

    if ($Required) {
        throw @"
Could not delete:
  $Path
Something is holding a lock on it. Pause OneDrive sync (system tray -> Pause
syncing), close Android Studio, then run this script again.
"@
    }
    Write-Warning "Could not delete $Path - continuing anyway."
    return $false
}

Remove-Stale -Path $gradleApk  -Required
Remove-Stale -Path $flutterApk -Required
Remove-Stale -Path $mappingDir
Remove-Stale -Path $artProfile

# NOTE: gradlew's console output must go straight to the host via Out-Host.
# A PowerShell function returns EVERYTHING left on its output stream, so
# `return $LASTEXITCODE` after an uncaptured `& .\gradlew.bat` would return the
# entire build log with the exit code appended -- and `$exitCode -ne 0` on that
# array is always true, turning a successful build into a reported failure.
$script:GradleExit = 0

function Invoke-GradleBuild {
    param([string[]]$ExtraArgs = @())

    Push-Location $androidRoot
    try {
        & .\gradlew.bat assembleRelease @ExtraArgs | Out-Host
        $script:GradleExit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

Push-Location $androidRoot
try { & .\gradlew.bat --stop | Out-Null } finally { Pop-Location }

Invoke-GradleBuild
$exitCode = $script:GradleExit

if ($exitCode -ne 0) {
    Write-Host ''
    Write-Warning 'Build failed. Retrying once without ART baseline-profile generation,'
    Write-Warning 'which is the step OneDrive most often locks. The APK is fully'
    Write-Warning 'functional without it (baseline profiles only speed up cold start).'
    Write-Host ''
    Remove-Stale -Path $artProfile
    Invoke-GradleBuild -ExtraArgs @('-PfingerspeakSkipArtProfile=true')
    $exitCode = $script:GradleExit
}

if ($exitCode -ne 0) {
    throw "gradlew assembleRelease failed with exit code $exitCode"
}

if (-not (Test-Path -LiteralPath $gradleApk)) {
    throw "Gradle reported success but $gradleApk was not produced."
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $flutterApk) | Out-Null
Copy-Item -LiteralPath $gradleApk -Destination $flutterApk -Force

$apk = Get-Item -LiteralPath $flutterApk
Write-Host ''
Write-Host "APK      : $($apk.FullName)"
Write-Host "Size     : $([math]::Round($apk.Length / 1MB, 1)) MB"
Write-Host "Built    : $($apk.LastWriteTime)"

if (Test-Path -LiteralPath $mappingDir) {
    Write-Warning 'R8 minification RAN for this build (mapping/release was produced).'
    Write-Warning 'That is only safe while android/app/proguard-rules.pro is wired up.'
} else {
    Write-Host 'Minified : no'
}

if ($Install) {
    if (-not (Test-Path -LiteralPath $adb)) { throw "adb not found at $adb" }
    $target = @()
    if ($Serial) { $target = @('-s', $Serial) }

    # A full uninstall (not `install -r`) clears any WorkManager/Room database
    # left behind by a previous broken build. `-r` preserves app data, which can
    # keep a corrupt database alive across reinstalls.
    Write-Host ''
    Write-Host 'Uninstalling any previous build...'
    & $adb @target uninstall org.fingerspeak.mobile 2>&1 | Out-Null

    Write-Host 'Installing...'
    & $adb @target install $flutterApk
    if ($LASTEXITCODE -ne 0) { throw "adb install failed with exit code $LASTEXITCODE" }

    & $adb @target shell am start -n org.fingerspeak.mobile/.MainActivity
    Write-Host ''
    Write-Host 'If it still crashes, capture the trace with:'
    $serialArg = if ($Serial) { "-s $Serial " } else { '' }
    Write-Host "  & `"$adb`" $($serialArg)logcat -d -s AndroidRuntime:E flutter:I"
}
