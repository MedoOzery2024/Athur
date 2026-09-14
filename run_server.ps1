# =============================================================================
# ATHUR · Start the backend server
# =============================================================================
# Starts the Dart/Shelf API + WebSocket server that the app talks to.
#
# HOW TO USE
#   1. Make sure PostgreSQL is running and the migrations are applied
#      (see db\scripts\migrate.ps1 and infra\docker-compose.yml).
#   2. Open a terminal in:  D:\Athur
#   3. Run:                 .\run_server.ps1
#
# The server reads its configuration from the git-ignored .env file at the repo
# root (JWT secret, database URL, Metered keys, Firebase service account).
#
# Verify it is up (in a second terminal):
#   Invoke-RestMethod http://localhost:8080/health
#   Invoke-RestMethod http://localhost:8080/health/ready
# =============================================================================

$ErrorActionPreference = 'Stop'

$env:Path = "D:\flutter\bin;$env:Path"

Write-Host "Athur · starting backend" -ForegroundColor Cyan

Set-Location (Join-Path $PSScriptRoot 'server')

# Confirm the .env exists so failures are obvious rather than mysterious.
$envFile = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path $envFile)) {
    Write-Warning ".env not found at $envFile — the server will refuse to start."
}

dart run bin/server.dart
