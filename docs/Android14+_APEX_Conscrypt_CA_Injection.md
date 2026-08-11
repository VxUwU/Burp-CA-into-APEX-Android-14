# Pre-Zygote APEX Conscrypt CA Injection (Android 14 / 15 / 16)

> A technique for installing a custom certificate authority into the trust store that Android 14+
> applications actually consult, by overlaying the read-only Conscrypt APEX certificate directory
> with a `tmpfs` + bind mount established **before the zygote is forked** (`post-fs-data`), packaged
> as a KernelSU / SukiSU module so the change is applied automatically at every boot and inherited
> by **every** application, current and future.

Validated on: Xiaomi (SDK 36 / Android 16), rooted with SukiSU Ultra / KernelSU (`ksud 4.1.3`),
against Burp Suite as the interception proxy. The technique applies to Android 14 (API 34) onward.

---

## 1. Symptom

With the Burp CA installed through Settings and a legacy "trust user certificates" module enabled,
only a subset of HTTPS traffic is intercepted; most applications fail the TLS handshake and appear
to have no connectivity. The certificate *appears* trusted in the UI, yet the majority of apps
reject it. This is the observable signature of a trust store that is present in the wrong location.

## 2. Root cause — the trust store moved into the Conscrypt APEX

Beginning with **Android 14 (API 34)**, Google relocated the system CA trust store so that it can be
updated out-of-band through the **Conscrypt APEX module** (`com.android.conscrypt`). The directory
applications read at runtime changed accordingly:

| | Android ≤ 13 | Android 14+ |
|---|---|---|
| Directory apps actually read | `/system/etc/security/cacerts/` | **`/apex/com.android.conscrypt/cacerts/`** |
| Adding a CA | `cp` after remounting `/system` rw | Not possible — the directory is **read-only** (signed APEX) |

Diagnostic snapshot from the target device:

```
Burp CA in /data/misc/user/0/cacerts-added/      -> present (user store, via Settings)
Burp CA in /system/etc/security/cacerts/         -> present (placed by the legacy module)
Burp CA in /apex/com.android.conscrypt/cacerts/  -> ABSENT   <-- root cause
```

Legacy "trust user certs" modules write to `/system/etc/security/cacerts/`, a path that is no longer
authoritative on Android 14+. Because applications resolve trust anchors from the APEX directory —
which does not contain the Burp CA — chain validation fails and the handshake is rejected.

## 3. Why a plain file copy cannot work

`/apex/com.android.conscrypt/cacerts/` is mounted read-only and backed by a signed APEX; writing to
it returns `Read-only file system`. The only way to add an anchor is to **overlay** the directory
with a writable one containing *the original system CAs plus the Burp CA*, using a bind mount. The
on-disk APEX is never modified.

## 4. The technique

The core sequence is identical whether applied at runtime or from the boot-time module:

```
1. Snapshot the existing system CAs from /apex/com.android.conscrypt/cacerts   (e.g. 143 files)
2. mount -t tmpfs over /system/etc/security/cacerts                            (a RAM-backed dir)
3. Repopulate it: the 143 system CAs + the Burp CA  ->  144 files
     owner root:root, mode 0644,
     SELinux label u:object_r:system_security_cacerts_file:s0   (required, or apps can't read it)
4. mount -o bind /system/etc/security/cacerts  ->  /apex/com.android.conscrypt/cacerts
```

Every operation is a `tmpfs`/bind mount held in RAM, so the change is **fully reversible** — it
disappears on reboot or when the module is disabled. No partition is touched, so the technique
cannot brick the device.

## 5. Key finding — the mount must precede the zygote

Injecting into the mount namespace of an **already-running zygote**
(`nsenter -t <zygote> -m -- mount ...`) does not propagate to applications:

- The zygote's own namespace reflects the overlay (`apex = 144`, Burp present).
- Yet freshly forked applications still observe `apex = 143` — the Burp CA is **not inherited**.

The cause is the Android application-spawn model: processes are created by `fork` + specialization,
drawn from a pre-forked **USAP** pool and given per-application mount namespaces. A mount added to a
zygote that is *already live* is not reliably copied into specialized children.

**Resolution:** perform the bind mount in the init/global namespace **before the zygote is forked**,
i.e. during the `post-fs-data` stage. Once the overlay is part of the base namespace, every
application forked from the zygote inherits it automatically — including apps installed later. This
requires no daemon, no per-spawn hook, and introduces no race condition.

> A per-spawn watcher was considered and rejected: it races the Conscrypt trust-store cache, imposes
> continuous CPU/battery overhead, and risks touching system processes — an early prototype that
> iterated every PID froze `system_server`.

## 6. Module implementation (KernelSU / SukiSU)

```
module.prop
post-fs-data.sh      # honors a WebUI "disabled" flag, then execs inject.sh
inject.sh            # shared apply / remove / status / list / apps / check / del logic
uninstall.sh         # removes user-store certs from every user profile on removal
webroot/index.html   # KernelSU WebUI: Control, Certs, Verify, Log
certs/<hash>.0       # optional bundled CA (DER), named by its subject hash
```

`post-fs-data.sh` runs before the zygote, waits for the APEX directory to be populated (a boot-timing
guard), then applies the sequence in §4 and records the outcome to `certfix.log`. A boot-time
self-test verifies a managed CA is visible in the base namespace and retries the bind once on
failure, so an unsupported device surfaces a clear `FAIL` in the log rather than failing silently.

Two additional exposures are handled beyond the APEX overlay:

- **Chrome / Chromium** enforce Certificate Transparency for anchors chaining to a *system* root and
  reject a system-only Burp CA (`ERR_CERTIFICATE_TRANSPARENCY_REQUIRED`). User-installed roots are
  CT-exempt, so the CA is additionally written to `cacerts-added` for every user profile.
- **Multi-user / work profiles** each maintain a separate user store; the module iterates all of
  `/data/misc/user/*`.

## 7. Verification

`/data/adb/modules/apex_burp_ca/certfix.log` after reboot:

```
apex ready after 0x100ms, apex_count=143
legacy tmpfs count=144
apex after bind=144
self-test: PASS (managed CA present in APEX overlay)
=== done ===
```

Inheritance is the decisive check — a process that started fresh at boot must already trust the CA:

```
zygote64          : APEX overlay contains the Burp CA
com.android.systemui : /apex/com.android.conscrypt/cacerts/<hash>.0 present  -> inherited
```

The WebUI **Verify** tab automates this per target: it `nsenter`s into a running application's mount
namespace and reports whether that process sees the CA — distinguishing "not trusted" from "pinned".

## 8. Scope and limitations

**Certificate pinning is out of scope.** Applications that pin (commonly banking and e-wallet apps)
accept only their own embedded certificate and ignore the system trust store entirely; no
CA-injection technique defeats this. Runtime unpinning with Frida or objection is the appropriate
tool. Likewise, Flutter applications bundle their own TLS stack and ignore both the system proxy and
the system trust store, and require a separate approach (e.g. reFlutter or a Frida hook on
`ssl_verify`).

**Detection surface.** The injected anchor is observable: an application that enumerates the trust
store can flag a CA whose subject matches a known interception tool (the WebUI flags such names),
and the bind mount is visible in `/proc/mounts`. Reducing this footprint (a neutral CA subject, a
system-only mode, or kernel-level mount hiding via SUSFS) is a defence-in-depth concern layered on
top of this technique, not provided by it.

## 9. Operational notes

- **Trust vs. routing are independent.** The CA makes applications *trust* the proxy; a proxy
  configuration *routes* traffic to it. Both are required to intercept.
- **Persistence.** The overlay is re-established on every boot by the module — no manual step. Only
  the proxy must be re-configured when the client address changes.
- **Rollback.** Disable or remove the module and reboot. The RAM-only overlay reverts completely,
  and a failing script cannot bootloop — boot simply proceeds without the CA.

## 10. References

1. HTTP Toolkit — *Android 14 blocks all methods to install system CA certificates* (Tim Perry).
   Primary practical reference for the `tmpfs` + bind + zygote-namespace approach.
   `httptoolkit.com/blog/android-14-install-system-ca-certificate/`
2. AOSP — Conscrypt APEX (`com.android.conscrypt`). Android 14 makes the CA store updatable via the
   APEX module. `android.googlesource.com/platform/external/conscrypt`
3. Conscrypt `TrustedCertificateStore` — the directory-based anchor lookup (by subject hash
   `<hash>.<n>`, PEM or DER). `android.googlesource.com/platform/external/conscrypt`
4. KernelSU / SukiSU — module guide (`post-fs-data.sh` ordering relative to the zygote, module
   format). `kernelsu.org/guide/module.html`
5. PortSwigger — *Installing Burp's CA certificate in an Android device*.
   `portswigger.net/burp/documentation/desktop/mobile/config-android-device`

> Confirm each URL and path against the current release before citing it in a formal report; AOSP
> paths and Android internals change between versions.
