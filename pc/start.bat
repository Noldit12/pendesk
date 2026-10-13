@echo off
title PenDesk USB
cd /d "%~dp0"
set PY=python
where py >nul 2>nul && set PY=py
%PY% pendesk_usb.py
if errorlevel 1 (
  echo.
  echo Fehler. Ist Python installiert?  https://www.python.org/downloads/
)
pause
