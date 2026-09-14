# Athur — Setup & Run Guide

All commands below are **PowerShell**, to be run **inside the stated directory**.
The Flutter SDK lives at `D:\flutter` and is not on PATH yet (see §0).

---

## 0. One-time: put Flutter on your PATH (recommended)

Without this, `flutter` is not recognised in a terminal. Run once, then
**restart VS Code**:

```powershell
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";D:\flutter\bin", "User")
```

Verify (in a **new** terminal):
```powershell
flutter --version
```

> If you prefer not to change PATH, prefix commands with the full path:
> `D:\flutter\bin\flutter.bat` instead of `flutter`.

---

## 1. Run the Flutter app

**Directory:** `D:\Athur\app`

```powershell
cd D:\Athur\app
flutter pub get
flutter analyze
flutter test
flutter run
```

To target a specific device:
```powershell
flutter devices
flutter run -d windows
flutter run -d <device-id>
```

**Regression-test the launcher icon / splash generation** (only if you change
the logo):
```powershell
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

---

## 2. Database (PostgreSQL)

### Option A — Docker (easiest)

**Directory:** `D:\Athur\infra`

```powershell
cd D:\Athur\infra
docker compose up -d
```

Then apply migrations — **Directory:** `D:\Athur`

```powershell
cd D:\Athur
$env:ATHUR_DATABASE_URL = "postgresql://athur:athur_dev_pw@localhost:5432/athur"
.\db\scripts\migrate.ps1
```

### Option B — Native PostgreSQL install

Install PostgreSQL 16, create a database and user, then run the same migration
command with your own URL.

### Verify the schema actually enforces its rules

**Directory:** `D:\Athur`

```powershell
psql $env:ATHUR_DATABASE_URL -v ON_ERROR_STOP=1 -f db/scripts/schema_test.sql
```

A clean run prints `ALL SCHEMA TESTS PASSED`. Any other outcome means the schema
is not behaving as specified.

---

## 3. Run the backend

**Directory:** `D:\Athur\server`

```powershell
cd D:\Athur\server
dart pub get
dart analyze
dart test
```

Then start it (the database must be running and migrated):

```powershell
cd D:\Athur\server
$env:ATHUR_DATABASE_URL = "postgresql://athur:athur_dev_pw@localhost:5432/athur"
$env:ATHUR_ENV = "development"
dart run bin/server.dart
```

### Verify the server is really working

In a **second** terminal:

```powershell
# Liveness — process is up
Invoke-RestMethod http://localhost:8080/health

# Readiness — performs a REAL database round-trip
Invoke-RestMethod http://localhost:8080/health/ready

# Build info
Invoke-RestMethod http://localhost:8080/version

# Unknown route must return a structured 404
try { Invoke-RestMethod http://localhost:8080/api/v1/nope } catch { $_.ErrorDetails.Message }
```

Expected: `/health` → `status: ok`; `/health/ready` → `status: ready`,
`database: up`; unknown route → `{"error":{"code":"NOT_FOUND",...}}`.

---

## 4. Environment variables

Copy the template and fill in real values (**never commit the `.env`**):

```powershell
cd D:\Athur
Copy-Item .env.example .env
```

| Variable | Required | Purpose |
|---|---|---|
| `ATHUR_DATABASE_URL` | **yes** | PostgreSQL connection string |
| `ATHUR_ENV` | no | `development` / `staging` / `production` |
| `ATHUR_HOST` / `ATHUR_PORT` | no | bind address (default `0.0.0.0:8080`) |

Future phases append `ATHUR_JWT_SECRET`, Firebase, Metered, storage and OAuth
variables — see `docs/CREDENTIALS.md`.

---

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `flutter : not recognized` | SDK not on PATH | §0, then restart the terminal |
| `ATHUR_DATABASE_URL is not set` | env var missing | set it before running the server |
| Server exits with code 69 | PostgreSQL unreachable | start the DB and check the URL/port |
| `/health/ready` returns 503 | DB down or migrations not applied | run `migrate.ps1` |
| `psql: not found` | client tools missing | install PostgreSQL client tools or use Docker |
| Migration fails midway | a SQL error in that file | `ON_ERROR_STOP=1` aborts cleanly; fix and re-run |
