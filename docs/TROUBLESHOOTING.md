# Troubleshooting — real-world field notes

Hard-won lessons from actual interception sessions (Xiaomi/MIUI, Android 14/16, SukiSU Ultra,
USB tether + Burp on a laptop). Read this before blaming the module or the CA — most "it broke"
cases are the environment, not `apex_burp_ca`.

Quick rule: the module puts the CA in `/apex/.../cacerts` and (for Chrome) the user store. If
`certfix.log` shows `VERIFY PASS` and the count went up by 1, **the module did its job** — look
outward.

---

## 1. Apps reject the cert right after installing/importing a NEW CA → **trust the MIUI prompt**
**Symptom:** brand-new custom/user CA, but apps fail with `certificate_unknown` / "connection poor"
even though the cert is clearly in the store.
**Cause (MIUI/Xiaomi):** installing a user/custom CA raises a **notification "Certificate authority
installed / trust this certificate?"**. Until you **tap it and choose Trust**, the CA is present but
**apps do not honor it**. It's a required activation step here, not a passive warning.
**Fix:** pull down the notification → **Trust** the cert. Then apps accept it.
> This was the actual root cause of a long "custom cert broke everything" session — everything else
> checked out; the cert just wasn't trusted yet.

## 2. "No internet" the moment you enable the proxy → **wrong proxy IP**
**Symptom:** all apps lose internet as soon as the phone proxy is on.
**Cause:** the proxy points at an IP the phone can't reach — classically a **WSL/Hyper-V vEthernet
IP (`172.29.x`)** instead of the **USB-tether IP (`10.x` on the "Remote NDIS" adapter)**. Ping to the
proxy IP from the phone failing is the tell (Windows Firewall blocks ICMP but not the TCP proxy port,
so ping fails even when the right port works).
**Fix (robust, IP-independent):** use loopback + `adb reverse`:
```
adb reverse tcp:8088 tcp:8088          # phone 127.0.0.1:8088 -> laptop Burp 127.0.0.1:8088
# set phone proxy to 127.0.0.1:8088
```
Loopback is never captured by a full-tunnel VPN and survives tether-IP changes. Verify:
```
adb shell "curl -s -x 127.0.0.1:8088 -o /dev/null -w '%{http_code}' http://example.com"   # expect 200
```
To restore internet fast: `adb shell settings put global http_proxy :0`.

**The chain drops on every USB reconnect** (scrcpy restart, reboot, re-plug): `adb reverse` is cleared
and Proxy Toggle re-detects a new LAN tether IP. Don't chase it — run the helper after each reconnect:
```
scripts\intercept-on.bat     # re-adds adb reverse + pins proxy to 127.0.0.1:8088 + tests
scripts\intercept-off.bat    # clears the proxy
```
Turn **Proxy Toggle off** entirely — the .bat sets the global proxy directly, and Proxy Toggle only
fights it by re-setting the wrong LAN IP. Burp needs a `127.0.0.1:8088` listener.

## 3. Bank/target apps show the *pristine* store (count unchanged) → **root-hiding unmounted the overlay**
**Symptom:** most apps (banks, etc.) reject the cert; a check shows their namespace has the **original
cert count** (e.g. 145) with your CA **absent**, while `systemui` and dev tools see it.
**Verify:**
```
adb shell su -mm -c 'pid=$(pidof <pkg>); nsenter -t ${pid%% *} -m -- ls /apex/com.android.conscrypt/cacerts | wc -l'
```
If a target app shows the same count as `nsenter -t 1` (real APEX) and yours is missing, the overlay
was **stripped from that app**.
**Cause:** SukiSU/KernelSU **"Umount Modules"** and/or the LSPosed module **Isolation Policy**
(`io.github.mhmrdd.isolationpolicy`) unmount module overlays from listed apps to hide root — which
removes the CA overlay too.
**Fix:** remove the target app from **Umount Modules** (SukiSU App Profile) **and** from **Isolation
Policy** scope, then force-stop + reopen (or reboot). Trade-off: root becomes visible to that app.
> Note: this is unnecessary if you bypass pinning with Frida (§4) — Frida makes the app accept any
> cert regardless of the trust store.

## 4. App trusts the CA but still won't intercept → **certificate pinning**
**Symptom:** Burp shows the connection but the client sends `Received fatal alert: certificate_unknown`,
or nothing decrypts for that app.
**Cause:** the app pins its own cert/key and ignores the OS trust store.
**Fix:** runtime unpinning:
```
frida -U -f <pkg> -l frida-multiple-unpinning.js
# or:  objection -g <pkg> explore  ->  android sslpinning disable
```
Frida output like `[+] Bypassing OkHTTPv3 {4}: <host>` means pinning is defeated and traffic flows.

## 5. Frida works, pinning bypassed, but the app crashes on an empty response → **upstream can't reach the backend**
**Symptom:** `org.json.JSONException: End of input at character 0` (empty body parsed as JSON), app
crashes at launch after login.
**Cause:** the app's API is on an **internal/VPN-only host** (e.g. `*.dev.<corp>`), and the machine
running Burp can't resolve/reach it → Burp returns empty.
**Verify on the Burp machine:** `nslookup <api-host>` must resolve; `curl https://<api-host>` must
connect. If GlobalProtect/VPN provides that host, Burp's **upstream path must go through the VPN**.
**Topologies that work:**
- VPN on the laptop (Burp machine) → Burp reaches internal directly.
- VPN on the phone + phone shares it (e.g. **Every Proxy**) → set Burp's **upstream proxy** to the
  phone's Every Proxy, so `app → Burp → phone VPN → internal API`.
Confirm the whole chain from the phone:
```
adb shell "curl -sk -x 127.0.0.1:8088 -o /dev/null -w '%{http_code}' https://<api-host>"   # expect 200
```

## 6. Chrome-only failure (other apps fine)
Chrome is stricter. If only Chrome fails: disable **Secure DNS** (Settings → Privacy → Use secure DNS
→ off) and **QUIC** (`chrome://flags` → Experimental QUIC → Disabled), and fully restart Chrome so it
re-reads the trust store. Browsers are a smoke-test only — real targets are the apps.

---

## CA mismatch — `certificate_unknown` / `ERR_CERT_AUTHORITY_INVALID` on every app
**Symptom:** the trust store clearly contains a CA and the MIUI prompt was trusted, yet apps (and
Chrome) still fail with `certificate_unknown` / `ERR_CERT_AUTHORITY_INVALID`.
**Cause:** the CA trusted on the device is **not the CA Burp is actually signing with**. This is the
classic trap when you install a *custom-named* CA on the device but forget that **Burp still signs
with its own loaded CA** (by default `PortSwigger CA`). Device trusts X, Burp presents a cert signed
by Y → rejected.
**Fix:** make the two match. Simplest — just trust **Burp's own CA** on the device (export it from
`http://burpsuite/cert` via the proxy, or Proxy settings → Import/export CA certificate → Export, and
add that to the module). Only bother with a renamed/custom CA if you also **import its `.p12` into
Burp** so Burp signs with it — otherwise the mismatch above is guaranteed.
**Verify which CA Burp uses:** through the proxy, fetch `http://burpsuite/cert` and check its
subject; it must equal the CA in the device trust store.
