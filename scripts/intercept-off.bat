@echo off
REM  intercept-off.bat  -  clear the phone proxy (restore normal internet)
set PORT=8088
echo [*] Clearing phone global proxy...
adb shell settings put global http_proxy :0
adb reverse --remove tcp:%PORT% >nul 2>&1
echo [OK] Proxy cleared. Phone back to direct internet.
