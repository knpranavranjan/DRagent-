@echo off
REM ===========================================================================
REM  OPHIRA - run the system on THIS PC only
REM
REM  Double-click this. It starts the session server and the MATLAB worker,
REM  then opens the browser. Nothing is published to the internet and no
REM  access key is needed, because the only client is this machine.
REM
REM  To share a link with another device, use "SHARE OPHIRA.bat" instead.
REM
REM  KEEP THIS WINDOW OPEN. Closing it stops the worker, and captures would
REM  then sit at "analysing" forever.
REM ===========================================================================
cd /d "%~dp0"
title OPHIRA - local (keep open)

python run.py
set EXITCODE=%ERRORLEVEL%

echo.
if not "%EXITCODE%"=="0" (
  echo ---------------------------------------------------------------
  echo  OPHIRA stopped with code %EXITCODE%.
  echo  Scroll up for the FAIL lines, or look in artifacts\logs\.
  echo.
  echo  "port 8000 is already in use" usually means it is still running
  echo  in another window. Close that one, or run:
  echo      python run.py --port 8001
  echo ---------------------------------------------------------------
)
pause
