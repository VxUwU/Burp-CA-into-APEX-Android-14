# Changelog

All notable changes to this module. Dates are ISO (UTC).

## [v1.5] — 2026-08-11
### Fixed
- **Accurate "Burp CA active in APEX" status in the WebUI.** The Control tab previously read
  `/apex/...` from the WebUI's own shell, which runs in a mount namespace that does **not** see the
  boot-time bind mount — so it falsely showed `no` even when injection succeeded. `inject.sh status`
  now reads the store from a **real app's namespace** (`nsenter` into `com.android.systemui`), so the
  count and the "active" flag reflect what apps actually see (e.g. `146` / `yes`). Falls back to a
  plain `ls` if `nsenter`/`pidof` is unavailable.

## [v1.4] — 2026-08-11
### Added
- **Delete a CA from the WebUI** (Certs tab). Removes the cert from its source dir + the user store,
  then re-applies so the APEX overlay drops it. Two-tap confirm (KSU WebViews often don't implement
  `window.confirm`). Bundled certs are labeled and warn that they return on reflash.
- **Update-proof imports (Option B).** Imported CAs are now saved to `/data/adb/apex_burp_ca_certs/`
  **outside** the module, so they **survive module updates/reflashes**. `inject.sh` loads certs from
  both the bundled `certs/` and this external dir; `uninstall.sh` cleans it up on removal.
- **Source tags** in the Certs list: `bundled` (shipped in the zip) vs `imported` (external, removable).
### Changed
- **Green glossy / frosted redesign** of the WebUI: emerald→teal accent, ambient gradient backdrop,
  layered sheen + inset highlight on glass, green glow on active tab/primary buttons. Fully theme-aware.
- `inject.sh` gained `list` and `del <name>` subcommands.

## [v1.3] — 2026-08-11
### Added
- **WebUI redesigned into 3 tabs: Control · Certs · Log.**
- **Certs tab** — view every loaded CA (subject, issuer, SHA-256 fingerprint, expiry with days-left),
  and **import a CA** by pasting PEM/DER. The Android `subject_hash_old` filename is computed
  **in-browser** (self-contained MD5 + SHA-256 + minimal ASN.1/X.509 parser), so **no `openssl` on the
  device is required**. Verified against a known cert: computed hash matches the `9a5ba575` filename.
- **Log tab** — auto-refresh toggle + copy-to-clipboard (with `execCommand` fallback).

## [v1.2] — 2026-08-11
### Added
- **KSU WebUI** (`webroot/index.html`) for SukiSU Ultra / KernelSU: view `certfix.log` and
  **enable/disable** injection without uninstalling.
- **Enable/Disable = persistent flag** honored by the boot script (`disabled` file), plus a best-effort
  live apply/remove. Reboot remains authoritative for already-running apps.
### Changed
- Refactored the injection logic into a shared **`inject.sh`** (`apply|remove|status`) used by
  `post-fs-data.sh`, the WebUI, and `uninstall.sh`. `post-fs-data.sh` now checks the flag and delegates.

## [v1.1] — 2026-08-11
### Added
- **Chrome / Chromium support.** The CA is now also installed into the **user** trust store
  (`/data/misc/user/0/cacerts-added`). Chrome enforces Certificate Transparency for certs chaining to a
  **system** root and rejects a system-only Burp CA (`ERR_CERTIFICATE_TRANSPARENCY_REQUIRED`); a
  **user-installed** root is CT-exempt, so Chrome trusts it.
- **`uninstall.sh`** — removes the persistent user-store cert when the module is disabled/removed
  (keeps the module cleanly reversible; the APEX/system part is RAM-only and reverts on reboot).
- **Firefox** documented: needs a one-time `about:config → security.enterprise_roots.enabled = true`
  (Firefox uses its own NSS store and ignores the OS trust store; can't be safely automated).
### Notes
- No change to the core APEX injection — the read-only Conscrypt APEX is still only **overlaid**
  (tmpfs + bind mount), never written to directly.

## [v1.0] — initial
- KernelSU/SukiSU module that injects a Burp/PortSwigger CA into the read-only Conscrypt **APEX** trust
  store (`/apex/com.android.conscrypt/cacerts`) at **post-fs-data** (before zygote) via tmpfs + bind
  mount, so **all apps** trust it. Fully reversible (RAM-only), cannot bootloop.

---

### At a glance — what changed since v1.0
| Area | v1.0 | Now (v1.5) |
|---|---|---|
| Apps (non-pinned) | ✅ trusts Burp | ✅ (unchanged core) |
| Chrome / Chromium | ❌ CT rejection | ✅ user-store CA (CT-exempt) |
| Firefox | ❌ | ✅ via documented one-time toggle |
| Manage certs | rebuild zip on PC | ✅ view / import / delete in WebUI (no openssl) |
| Imports survive updates | — | ✅ external dir `/data/adb/apex_burp_ca_certs/` |
| UI | none | ✅ green glossy WebUI (Control · Certs · Log) |
| Reversible / clean removal | ✅ | ✅ + `uninstall.sh` cleans user store & imports |
