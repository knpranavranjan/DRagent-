@echo off
REM ===========================================================================
REM  OPHIRA - run the system and publish a link you can open anywhere
REM
REM  Double-click this. It starts three things and prints a public HTTPS link:
REM
REM      the session server      takes captures, serves the UI
REM      the MATLAB worker       runs the five models
REM      the tunnel              makes it reachable from outside this PC
REM
REM  KEEP THIS WINDOW OPEN. Closing it closes the link and stops the worker.
REM
REM  The link contains an access key. Anyone holding the link has full access,
REM  so send it privately. The key is reused from .ophira_key; delete that
REM  file to rotate it and every old link dies at once.
REM ===========================================================================
cd /d "%~dp0"
title OPHIRA - shared link (keep open)

python run.py --tunnel
set EXITCODE=%ERRORLEVEL%

echo.
if not "%EXITCODE%"=="0" (
  echo ---------------------------------------------------------------
  echo  OPHIRA stopped with code %EXITCODE%.
  echo  Scroll up for the FAIL lines, or look in artifacts\logs\.
  echo ---------------------------------------------------------------
)
pause
