# =============================================================================
# ATHUR - Public tunnel (ngrok) - makes the app reachable from ANY network
# =============================================================================
# WHY THIS EXISTS
#   A phone on 4G/5G cannot reach "localhost" or the PC's LAN IP. ngrok exposes
#   the local backend on a public HTTPS URL, so Athur works across
#   Wi-Fi ? 4G/5G in BOTH directions, with TLS.
#
# HOW TO USE
#   1. Terminal 1 (repo root):  .\run_server.ps1        <- start the backend
#   2. Terminal 2 (repo root):  .\run_tunnel.ps1        <- start ngrok
#   3. Copy the https URL it prints.
#   4. Build the APK pointing at that URL:
#        .\build_apk.ps1 -ApiBase "https://<your-url>.ngrok-free.dev"
#
# NOTE: free ngrok URLs change every restart. Rebuild (or re-run the app) with
# the new URL each time. A reserved domain avoids that - see docs/NGROK.md.
# =============================================================================

param(
    [int]$Port = 8080
)

$ErrorActionPreference = 'Stop'

$ngrok = Join-Path $PSScriptRoot 'tools\ngrok.exe'
if (-not (Test-Path $ngrok)) {
    Write-Error "ngrok not found at $ngrok. Place ngrok.exe in the tools\ folder."
    exit 1
}

Write-Host "Athur - starting public tunnel for http://localhost:$Port" -ForegroundColor Cyan

# Run ngrok in the background so we can query its local API for the URL.
Start-Process -FilePath $ngrok `
    -ArgumentList 'http', "$Port", '--log', 'stdout' `
    -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $PSScriptRoot 'ngrok_log.txt') `
    -RedirectStandardError (Join-Path $PSScriptRoot 'ngrok_err.txt')

# Wait for the tunnel to come up, then read the public URL.
$url = $null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 800
    try {
        $tunnels = Invoke-RestMethod 'http://localhost:4040/api/tunnels' -TimeoutSec 4
        $url = ($tunnels.tunnels | Where-Object { $_.public_url -like 'https://*' } | Select-Object -First 1).public_url
        if ($url) { break }
    } catch {
        # ngrok's local API is not ready yet - keep waiting.
    }
}

if (-not $url) {
    Write-Error "Could not read the ngrok URL. Check ngrok_log.txt / ngrok_err.txt."
    exit 1
}

Write-Host ""
Write-Host "  PUBLIC URL: $url" -ForegroundColor Green
Write-Host ""
Write-Host "  Build the APK against it with:" -ForegroundColor Yellow
Write-Host "    .\build_apk.ps1 -ApiBase `"$url`""
Write-Host ""
Write-Host "  Verify the tunnel:" -ForegroundColor Yellow
Write-Host "    curl.exe -H `"ngrok-skip-browser-warning: true`" `"$url/health`""
Write-Host ""
