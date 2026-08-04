# Android 14+ APEX Conscrypt CA Injector

KernelSU / **SukiSU Ultra** module that installs a custom CA certificate (e.g. **Burp Suite / PortSwigger CA**) into the **Conscrypt APEX trust store** (`/apex/com.android.conscrypt/cacerts`) at **`post-fs-data` (before zygote)**, so **every app** — current and future-installed — trusts it automatically.

> For **authorized** mobile security testing / research only. See [Disclaimer](#disclaimer).

Tested on: Xiaomi `25098RA98G`, Android **16 (SDK 36)**, **SukiSU Ultra / KernelSU** (`ksud 4.1.3`), Burp Suite.

---

## Why this is needed (Android 14+)

Since **Android 14 (API 34)** the system CA store apps actually read moved to the read-only **Conscrypt APEX**:

| | Android ≤13 | Android 14+ |
|---|---|---|
| Store apps read | `/system/etc/security/cacerts/` | `/apex/com.android.conscrypt/cacerts/` (read-only APEX) |
| Add a CA | `cp` file after `mount -o rw` | ❌ can't write — must overlay via bind mount |

Old "trust user certs" modules write to `/system/etc/...` which is now **ignored**, so HTTPS interception fails for most apps. This module overlays the APEX store with `system CAs + your CA` via **tmpfs + bind mount**, done **before zygote starts** so all forked apps inherit it.

📖 **New here? Start with the step-by-step [Tutorial](docs/TUTORIAL.md).**
Full technical writeup: [`docs/Android14+_APEX_Conscrypt_CA_Injection.md`](docs/Android14+_APEX_Conscrypt_CA_Injection.md)

## Repo layout

```
.
├── README.md
├── LICENSE
├── .gitignore
├── module-source/            # editable module source
│   ├── module.prop
│   ├── post-fs-data.sh        # runs pre-zygote, does the injection
│   ├── build_mod.sh           # rebuilds the flashable zip (WSL/Linux)
│   └── certs/<hash>.0         # your CA (DER), named by subject hash
├── scripts/
│   └── inject_app_runtime.sh  # no-reboot per-app fallback injector
├── docs/
│   └── Android14+_APEX_Conscrypt_CA_Injection.md
└── dist/
    └── apex_burp_ca_module.zip  # built module (optional to commit)
```

## Install

1. Put **your** Burp/CA cert in `module-source/certs/` (see [Using your own CA](#using-your-own-ca)).
2. Build the zip: `bash module-source/build_mod.sh` (needs `zip`; runs on WSL/Linux).
3. SukiSU Ultra Manager → **Modules → Install from storage** → pick the zip → **Reboot**.

## Using your own CA

Burp generates a **unique CA per installation**. Export yours and add it:

```bash
# Export Burp CA (DER) from Burp: Proxy > Proxy settings > Import/export CA certificate
# Compute Android hash name and copy in:
HASH=$(openssl x509 -inform DER -in cacert.der -subject_hash_old -noout)
cp cacert.der module-source/certs/$HASH.0
```

Only the **public** CA certificate is stored — never the private key (that stays in Burp).

## Verify (after reboot)

```
cat /data/adb/modules/apex_burp_ca/certfix.log
# expect: legacy tmpfs count=... / apex after bind=... / === done ===
```

Or check any freshly-started app's namespace sees your CA in `/apex/com.android.conscrypt/cacerts/`.

## Rollback

SukiSU Manager → disable/remove module → **reboot**. Fully reverts (tmpfs/bind live only in RAM). Cannot bootloop: if the script fails, boot continues without the CA.

## Limitations

- **Certificate pinning** apps (banking / e-wallet) reject even trusted system CAs → needs Frida/objection unpinning (out of scope).
- Proxy still must be configured separately — the CA makes apps *trust* Burp, the proxy *routes* traffic to it.

## References

- HTTP Toolkit — *Android 14 blocks all methods to install system CA certificates*
- AOSP — Conscrypt APEX (`com.android.conscrypt`)
- KernelSU / SukiSU — Module guide (`post-fs-data.sh` ordering)
- PortSwigger — Installing Burp's CA on Android

## Disclaimer

Intended for security testing on devices and apps you own or are **explicitly authorized** to test. You are responsible for complying with applicable laws and agreements. Provided as-is, no warranty.
