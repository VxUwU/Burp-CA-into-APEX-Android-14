@echo off
REM ============================================================
REM  intercept-on.bat  -  restore the phone->Burp proxy chain
REM  Run this after EVERY USB reconnect / scrcpy restart / reboot.
REM
REM  Chain: app -> phone 127.0.0.1:8088 -> (adb reverse) -> laptop Burp 127.0.0.1:8088
REM  Loopback survives tether-IP changes AND a full-tunnel VPN on the phone.
REM  Make sure Burp has a listener on 127.0.0.1:8088.
REM ============================================================
set PORT=8088

echo [*] Re-establishing adb reverse (phone %PORT% -> laptop %PORT%)...
adb reverse --remove tcp:%PORT% >nul 2>&1
adb reverse tcp:%PORT% tcp:%PORT%
if errorlevel 1 (
  echo [!] adb reverse failed - is the device connected? ^(adb devices^)
  goto :end
)

echo [*] Pinning phone proxy to 127.0.0.1:%PORT% (ignore Proxy Toggle's auto LAN IP)...
adb shell settings put global http_proxy 127.0.0.1:%PORT%

echo [*] Current proxy:
adb shell settings get global http_proxy

echo [*] Testing chain through Burp...
adb shell "curl -s -m 8 -x 127.0.0.1:%PORT% -o /dev/null -w \"    public = %%{http_code}\n\" http://example.com"
echo.
echo [OK] If public = 200, the chain is up. Now run frida and open the app.
echo      frida -U -f ^<package^> -l bri.js --no-pause
:end
