[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ResearchRoot = $PSScriptRoot
$RepositoryRoot = (Resolve-Path (Join-Path $ResearchRoot '..\..')).Path
$MobileRoot = Join-Path $RepositoryRoot 'apps\mobile'
$EntryPoint = Join-Path $ResearchRoot 'bin\fingerspeak_benchmark.dart'
$ProfileApk = Join-Path $MobileRoot 'build\app\outputs\flutter-apk\app-profile.apk'

function Resolve-Executable {
    param(
        [string]$EnvironmentValue,
        [string[]]$Candidates,
        [string]$CommandName,
        [string]$FriendlyName
    )

    if ($EnvironmentValue -and (Test-Path -LiteralPath $EnvironmentValue -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $EnvironmentValue).Path
    }
    foreach ($Candidate in $Candidates) {
        if ($Candidate -and (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }
    $Located = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($Located) { return $Located.Source }
    throw "$FriendlyName was not found. Set its FingerSpeak environment variable or install the Android/Flutter tooling."
}

function Resolve-Adb {
    $Candidates = @()
    if ($env:ANDROID_SDK_ROOT) {
        $Candidates += Join-Path $env:ANDROID_SDK_ROOT 'platform-tools\adb.exe'
    }
    if ($env:ANDROID_HOME) {
        $Candidates += Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
    }
    if ($env:LOCALAPPDATA) {
        $Candidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    }
    return Resolve-Executable -EnvironmentValue $env:FINGERSPEAK_ADB `
        -Candidates $Candidates -CommandName 'adb' -FriendlyName 'Android Debug Bridge (adb)'
}

function Resolve-Flutter {
    $Candidates = @()
    if ($env:USERPROFILE) {
        $Candidates += Join-Path $env:USERPROFILE 'Development\flutter\bin\flutter.bat'
    }
    return Resolve-Executable -EnvironmentValue $env:FINGERSPEAK_FLUTTER `
        -Candidates $Candidates -CommandName 'flutter' -FriendlyName 'Flutter'
}

function Resolve-Dart {
    $Candidates = @()
    if ($env:FINGERSPEAK_FLUTTER) {
        $FlutterBin = Split-Path -Parent $env:FINGERSPEAK_FLUTTER
        $Candidates += Join-Path $FlutterBin 'cache\dart-sdk\bin\dart.exe'
    }
    if ($env:USERPROFILE) {
        $Candidates += Join-Path $env:USERPROFILE 'Development\flutter\bin\cache\dart-sdk\bin\dart.exe'
    }
    return Resolve-Executable -EnvironmentValue $env:FINGERSPEAK_DART `
        -Candidates $Candidates -CommandName 'dart' -FriendlyName 'Dart'
}

function Build-ResearchApk {
    $Flutter = Resolve-Flutter
    Write-Host 'Building profile APK with hidden research telemetry enabled...'
    Push-Location $MobileRoot
    try {
        & $Flutter build apk --profile --dart-define=FINGERSPEAK_RESEARCH=true
        if ($LASTEXITCODE -ne 0) { throw "Flutter build failed with exit code $LASTEXITCODE." }
    }
    finally {
        Pop-Location
    }
    Write-Host "Research APK: $ProfileApk"
}

function Install-ResearchApk {
    if (-not (Test-Path -LiteralPath $ProfileApk -PathType Leaf)) {
        throw "Research APK not found at $ProfileApk. Run build-research first."
    }
    $Adb = Resolve-Adb
    Write-Host 'Installing the research profile APK on the connected Android device...'
    & $Adb install -r $ProfileApk
    if ($LASTEXITCODE -ne 0) { throw "adb install failed with exit code $LASTEXITCODE." }
}

switch ($Command.ToLowerInvariant()) {
    'build-research' {
        Build-ResearchApk
        exit 0
    }
    'install-research' {
        Install-ResearchApk
        exit 0
    }
    'build-install' {
        Build-ResearchApk
        Install-ResearchApk
        exit 0
    }
    default {
        if (-not (Test-Path -LiteralPath $EntryPoint -PathType Leaf)) {
            throw "Benchmark entry point not found at $EntryPoint."
        }
        $Dart = Resolve-Dart
        $CliArgs = @($Command) + @($RemainingArgs)
        if ($Command.ToLowerInvariant() -in @('doctor', 'collect', 'trace')) {
            $HasAdb = @($RemainingArgs | Where-Object { $_ -match '^--adb(?:=|$)' }).Count -gt 0
            if (-not $HasAdb) {
                $CliArgs += @('--adb', (Resolve-Adb))
            }
        }
        & $Dart $EntryPoint @CliArgs
        exit $LASTEXITCODE
    }
}
