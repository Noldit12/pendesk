@echo off
title PenDesk USB
cd /d "%~dp0"
set PY=python
where py >nul 2>nul && set PY=py
%PY% -c "import simplejpeg, numpy" >nul 2>nul || (
  echo Installiere einmalig den schnellen Bild-Kodierer ...
  %PY% -m pip install --disable-pip-version-check -q simplejpeg numpy || %PY% -m pip install --disable-pip-version-check -q pillow
)
%PY% pendesk_usb.py
if errorlevel 1 (
  echo.
  echo Fehler. Ist Python installiert?  https://www.python.org/downloads/
)
pause
