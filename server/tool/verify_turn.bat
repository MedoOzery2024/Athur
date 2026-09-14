@echo off
REM ===========================================================================
REM  ATHUR · Live TURN verification
REM ===========================================================================
REM  Proves the server can obtain REAL ICE servers from the Metered account
REM  configured in ..\.env, using the server-side API key only.
REM
REM  Run from the server\ directory:   tool\verify_turn.bat
REM
REM  Environment variables (ATHUR_METERED_DOMAIN / ATHUR_METERED_API_KEY) must
REM  already be set, e.g. via the values documented in docs\CREDENTIALS.md.
REM  This script NEVER prints the key.
REM ===========================================================================
setlocal

if "%ATHUR_METERED_DOMAIN%"=="" (
  echo [FAIL] ATHUR_METERED_DOMAIN is not set.
  exit /b 1
)
if "%ATHUR_METERED_API_KEY%"=="" (
  echo [FAIL] ATHUR_METERED_API_KEY is not set.
  exit /b 1
)

echo [INFO] Domain : %ATHUR_METERED_DOMAIN%
echo [INFO] Key    : [hidden]
echo.

REM Delegate to the Dart verifier, which reuses the production service code.
dart run tool\verify_turn.dart
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
