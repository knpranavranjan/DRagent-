@echo off
REM ============================================================
REM  OPHIRA - start the encounter server
REM
REM  Then, in a MATLAB window:
REM      >> startup_ophira
REM      >> ophira.worker.run
REM
REM  The worker runs the quality gate on captured images. Without
REM  it the UI will report "No response from the analysis worker"
REM  rather than silently passing an unassessed image.
REM ============================================================
cd /d "%~dp0"
echo Starting OPHIRA encounter server on http://127.0.0.1:8000/
echo.
echo   Remember to start the MATLAB worker:  ophira.worker.run
echo.
python app\server\ophira_server.py --port 8000
pause
