@echo off
rem Double-click launcher for OpenDesignRepair.ps1 (bypasses execution policy).
rem Any arguments are forwarded, e.g.:  OpenDesignRepair.cmd doctor
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0OpenDesignRepair.ps1" %*
echo.
pause