# =============================================================================
# ATHUR · Build the release APK
# =============================================================================
# Produces a signed-for-testing release APK at:
#   app\build\app\outputs\flutter-apk\app-release.apk
#
# HOW TO USE
#   1. Open a terminal in:  D:\Athur
#   2. Run:                 .\build_apk.ps1
#
# Optional: point the app at a real server instead of the Android-emulator alias
#   .\build_apk.ps1 -ApiBase "http://192.168.1.5:8080"
#
# IMPORTANT about signing:
#   The build currently uses the DEBUG signing key (see build.gradle.kts).
#   That is fine for installing on your own phone for testing, but it is NOT
#   suitable for distribution. A real release key is added in the update phase.
# =============================================================================

param(
    [string]$ApiBase = ""
)

$ErrorActionPreference = 'Stop'

$jbr = 'C:\Program Files\Android\Android Studio\jbr'
if (Test-Path $jbr) { $env:JAVA_HOME = $jbr; $env:Path = "$jbr\bin;$env:Path" }
$env:Path = "D:\flutter\bin;$env:Path"

Write-Host "Athur · building release APK" -ForegroundColor Cyan
if ($ApiBase -ne "") { Write-Host "  API base: $ApiBase" }

Set-Location (Join-Path $PSScriptRoot 'app')

if ($ApiBase -ne "") {
    flutter build apk --release --dart-define=ATHUR_API_BASE=$ApiBase
} else {
    flutter build apk --release
}

$apk = Join-Path $PSScriptRoot 'app\build\app\outputs\flutter-apk\app-release.apk'
if (Test-Path $apk) {
    $sizeMb = [math]::Round((Get-Item $apk).Length / 1MB, 1)
    Write-Host ""
    Write-Host "APK ready ($sizeMb MB):" -ForegroundColor Green
    Write-Host "  $apk"
} else {
    Write-Error "Build finished but no APK was found at $apk"
}
