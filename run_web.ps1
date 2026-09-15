# =============================================================================
# ATHUR - Run the app as a WEBSITE (web target)
# =============================================================================
# Opens Athur in a Chrome/Edge tab for quick testing and demos.
#
# HOW TO USE
#   1. Open a terminal in:  D:\Athur
#   2. Run:                 .\run_web.ps1
#
# What it does:
#   * points Flutter at the local backend (http://localhost:8080)
#   * starts the web dev server and opens the browser
#
# NOTE: the backend must be running first (see run_server.ps1), otherwise the
# app's API calls will fail even though the UI loads.
# =============================================================================

param(
    [string]$ApiBase = "http://localhost:8080",
    [string]$Device = "chrome"
)

$ErrorActionPreference = 'Stop'

# Make Flutter + Android Studio's JDK available in this session.
$jbr = 'C:\Program Files\Android\Android Studio\jbr'
if (Test-Path $jbr) { $env:JAVA_HOME = $jbr; $env:Path = "$jbr\bin;$env:Path" }
$env:Path = "D:\flutter\bin;$env:Path"

Write-Host "Athur - running as website" -ForegroundColor Cyan
Write-Host "  backend : $ApiBase"
Write-Host "  device  : $Device"
Write-Host ""

Set-Location (Join-Path $PSScriptRoot 'app')

# The backend sends proper CORS headers for localhost origins (see
# server/lib/src/api/middleware/cors_middleware.dart), so no browser security
# flags are needed. The API base is injected so no source edit is required.
flutter run -d $Device --dart-define=ATHUR_API_BASE=$ApiBase
