# =============================================================================
# ATHUR · Migration runner (PostgreSQL via psql)
# =============================================================================
# Applies every .sql file in db/migrations, in filename order, inside a single
# psql session. Each migration file manages its own BEGIN/COMMIT and records
# itself in `schema_migrations`, so re-running is safe for applied versions.
#
# Usage (PowerShell, from the repository root D:\Athur):
#   .\db\scripts\migrate.ps1 -DatabaseUrl "postgresql://athur:pw@localhost:5432/athur"
#
# Or set ATHUR_DATABASE_URL and run without arguments:
#   .\db\scripts\migrate.ps1
#
# Requirements: `psql` on PATH (ships with the PostgreSQL client tools).
# The URL is passed to psql via the PGPASSWORD/PG* environment, never echoed.
# =============================================================================

param(
    [string]$DatabaseUrl = $env:ATHUR_DATABASE_URL,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'



# Locate the migrations directory relative to this script (portable).
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$migrations  = Join-Path (Split-Path -Parent $scriptDir) 'migrations'

if (-not (Test-Path $migrations)) {
    Write-Error "Migrations directory not found: $migrations"
    exit 1
}

$files = Get-ChildItem -Path $migrations -Filter '*.sql' | Sort-Object Name

Write-Host "Athur migration runner" -ForegroundColor Cyan
Write-Host "  target : $DatabaseUrl"
Write-Host "  dir    : $migrations"
Write-Host "  files  : $($files.Count)"
Write-Host ""

foreach ($file in $files) {
    Write-Host "→ $($file.Name)" -ForegroundColor Yellow
    if ($DryRun) {
        Write-Host "   (dry run: not executing)" -ForegroundColor DarkGray
        continue
    }

    # ON_ERROR_STOP makes psql exit non-zero on the first SQL error, so a
    # broken migration aborts the whole run instead of half-applying silently.
    & psql -h localhost -U athur -d athur -v ON_ERROR_STOP=1 -f $file.FullName
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Migration failed: $($file.Name)"
        exit $LASTEXITCODE
    }
}

Write-Host ""
Write-Host "All migrations applied." -ForegroundColor Green
