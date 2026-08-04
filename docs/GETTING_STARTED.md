# Getting Started: Trust your Burp CA on Android 14/15/16 (all apps)

A complete, beginner-friendly walkthrough. By the end, **every app** on your rooted device
will trust your Burp Suite CA, so you can intercept HTTPS traffic.

> ⚠️ **Authorized use only.** Do this on devices/apps you own or are explicitly allowed to test.

---

## 0. What you need

| Requirement | Notes |
|---|---|
| Rooted Android **14/15/16** | with **KernelSU / SukiSU Ultra** (Magisk works too, adapt install step) |
| **Burp Suite** on your PC | Community or Pro |
| **PC + device on the same network** | Wi-Fi, or USB/LAN tether |
| `openssl` + `zip` | on WSL / Linux / macOS to build the module |
| `adb` (optional) | for verification |

Two independent things must both be true to intercept HTTPS:
- **Trust** — the app must trust Burp's CA (this module does that).
- **Routing** — traffic must go through Burp (you set a **proxy** on the device).

---

## 1. Export your Burp CA certificate

1. In Burp: **Proxy → Proxy settings → TLS** (older versions: *Import / export CA certificate*).
2. Choose **Export → Certificate in DER format** → save as `cacert.der`.

> Only the **public** certificate. Never export/commit the private key or a `.p12`.

## 2. Add your cert to the module

Android names CA files by a **subject hash**. Compute it and copy the cert into `module-source/certs/`:

```bash
HASH=$(openssl x509 -inform DER -in cacert.der -subject_hash_old -noout)
cp cacert.der module-source/certs/$HASH.0
echo "added module-source/certs/$HASH.0"
```

Your `certs/` folder should now contain one file like `9a5ba575.0`.

## 3. Build the module zip

```bash
bash module-source/build_mod.sh
```

This produces `dist/apex_burp_ca_module.zip`. The script normalizes line endings to LF
(so the boot script runs correctly on Android) and puts `module.prop` at the zip root.

## 4. Install on the device

1. Copy `dist/apex_burp_ca_module.zip` to your phone (e.g. `adb push` or any file transfer).
2. Open **SukiSU Ultra Manager → Modules → Install from storage** → select the zip.
   *(KernelSU Manager is the same. On Magisk: Modules → Install from storage.)*
3. **Reboot.** (The cert is injected at boot, before apps start.)

## 5. Verify it worked

After reboot, check the module's log:

```bash
adb shell "su -c 'cat /data/adb/modules/apex_burp_ca/certfix.log'"
```

Expected:

```
apex ready after ...
legacy tmpfs count=<N+1>
apex after bind=<N+1>
=== done ===
```

Optional deeper proof — a freshly started app trusts your CA:

```bash
adb shell "su -mm -c 'nsenter -t \$(pidof com.android.systemui) -m -- ls /apex/com.android.conscrypt/cacerts | wc -l'"
```

## 6. Set up the proxy and intercept

1. In Burp: **Proxy → Proxy settings → add a listener** on your PC's LAN IP (or *All interfaces*), e.g. port `8080`.
2. On the device, set the network proxy to `<PC-IP>:<port>`
   (Wi-Fi settings → modify network → Proxy = Manual; or an app like *ProxyToggle*/*Every Proxy* for tether).
3. Open any app and use it — traffic appears in **Burp → Proxy → HTTP history**, decrypted, no cert errors.

> Tip: keep Burp **Intercept OFF** and read **HTTP history**; leaving Intercept ON holds every
> request until you click Forward, which looks like "no internet".

## 7. Installing new apps later

Nothing to do. The CA lives in the trust store **before zygote**, so **any** app — including
ones you install months from now — inherits it automatically on launch. Zero maintenance.

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| Only some sites work, most "no internet" | **Intercept is ON** in Burp → turn it OFF; use HTTP history. |
| `net::ERR_CERT_AUTHORITY_INVALID` in a browser | CA not trusted → check `certfix.log`; confirm cert is in `certs/<hash>.0` and you rebooted. |
| `certfix.log` missing after reboot | Module not active → confirm it's enabled in SukiSU, and that you rebooted **after** install. |
| App shows connection error but Burp sees nothing | Likely **certificate pinning** (banking / e-wallet). Needs Frida/objection unpinning — see below. |
| Boot fine but no interception | Proxy not set / Burp listener not bound to a reachable IP. Re-set proxy (tether IPs change). |
| Script "works" via `su` but no effect | Use `su -mm` (mount-master / global namespace) for manual mounts. |

## About certificate pinning

Some apps only accept **their own** pinned certificate and ignore the system trust store.
No CA-injection technique defeats this. To test those apps you need runtime unpinning with
**Frida** or **objection** — that's a separate setup, out of scope for this module.

## How it works (short version)

Android 14+ apps read CAs from the **read-only** `/apex/com.android.conscrypt/cacerts`.
You can't write into it, so the module overlays it (tmpfs + bind mount) with
`system CAs + your CA`, executed at **`post-fs-data` before zygote** so every forked app
inherits the trust store. Full details: [`Android14+_APEX_Conscrypt_CA_Injection.md`](Android14+_APEX_Conscrypt_CA_Injection.md).

Everything is RAM-only (tmpfs/bind): removing the module + rebooting fully reverts it, and it
cannot bootloop — if the script fails, boot simply continues without the CA.
