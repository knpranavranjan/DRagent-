@echo off
setlocal EnableDelayedExpansion
REM ===========================================================================
REM  OPHIRA - set up a permanent address (run this ONCE)
REM
REM  After this, SHARE OPHIRA.bat always publishes on the SAME URL, so a link
REM  you put on a slide or a QR code keeps working.
REM
REM  You need a free ngrok account. It takes about two minutes and gives you
REM  one reserved domain at no cost.
REM ===========================================================================
cd /d "%~dp0"
title OPHIRA - one-time setup

set "NGROK=tools\ngrok.exe"
if not exist "%NGROK%" (
  where ngrok >nul 2>&1 && (for /f "delims=" %%i in ('where ngrok') do set "NGROK=%%i")
)
if not exist "%NGROK%" (
  echo.
  echo   ngrok.exe was not found in tools\ and is not on PATH.
  echo   Download it from https://ngrok.com/download and put it in:
  echo       %CD%\tools\
  echo.
  pause
  exit /b 1
)

echo.
echo  ============================================================
echo   STEP 1 of 3   Create the free account
echo  ============================================================
echo.
echo   Opening https://dashboard.ngrok.com/signup
echo   Sign up (Google/GitHub login is fastest), then come back here.
echo.
pause
start "" "https://dashboard.ngrok.com/signup"
echo.
pause

echo.
echo  ============================================================
echo   STEP 2 of 3   Your authtoken
echo  ============================================================
echo.
echo   Opening the page with your authtoken. Copy it.
echo.
start "" "https://dashboard.ngrok.com/get-started/your-authtoken"
echo.
set /p TOKEN=  Paste your authtoken here and press Enter:
if "!TOKEN!"=="" (
  echo.
  echo   Nothing entered. Run this again when you have the token.
  pause
  exit /b 1
)
"%NGROK%" config add-authtoken !TOKEN!
if errorlevel 1 (
  echo.
  echo   ngrok rejected that token. Check you copied all of it.
  pause
  exit /b 1
)
echo   Authtoken saved.

echo.
echo  ============================================================
echo   STEP 3 of 3   Claim your free permanent domain
echo  ============================================================
echo.
echo   Opening your Domains page.
echo     - Click "+ New Domain" (or "Create Domain")
echo     - ngrok offers you a free one, something like
echo         kind-shark-42.ngrok-free.app
echo     - Copy the whole thing.
echo.
start "" "https://dashboard.ngrok.com/domains"
echo.
set /p DOMAIN=  Paste your domain here and press Enter:
if "!DOMAIN!"=="" (
  echo.
  echo   Nothing entered. Run this again when you have the domain.
  pause
  exit /b 1
)
> ".ngrok_domain" echo !DOMAIN!

echo.
echo  ============================================================
echo   Done.
echo  ============================================================
echo.
echo   Your permanent address is:
echo.
echo       https://!DOMAIN!
echo.
echo   From now on, double-click SHARE OPHIRA.bat and the link in
echo   SHARE LINK.txt will always use this address.
echo.
echo   It only answers while that launcher window is open - the
echo   address is permanent, your PC still has to be running.
echo.
pause
