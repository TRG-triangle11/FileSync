@echo off
rem ============================================================
rem  FileSync console launcher  (ASCII only on purpose)
rem  cmd.exe mis-reads batch files that contain multi-byte text
rem  right after a chcp switch - it then tries to execute path
rem  fragments as commands. So: no Chinese in .cmd, ever.
rem  All Chinese output comes from the .ps1 files (UTF-8 + BOM).
rem ============================================================
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title FileSync Console

if not exist "%~dp0Serve-Console.ps1" goto nofile

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Serve-Console.ps1" %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" goto failed
exit /b 0

:nofile
echo.
echo   [ERROR] Serve-Console.ps1 is not in this folder.
echo   Move the whole FileSync folder together, do not copy
echo   this launcher alone.
echo.
pause
exit /b 1

:failed
echo.
echo   [INFO] Console exited with code %RC%.
echo   The lines above explain why.
echo.
pause
exit /b %RC%
