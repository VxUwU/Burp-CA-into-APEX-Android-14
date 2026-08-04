# Teknik: Pre-Zygote APEX Conscrypt CA Injection (Android 14/15/16)

> Menanam Burp/PortSwigger CA ke **system trust store** yang benar di Android 14+
> lewat **tmpfs + bind mount** yang dijalankan **sebelum zygote lahir** (`post-fs-data`),
> dikemas sebagai **module KernelSU/SukiSU** agar permanen & berlaku untuk **semua app**.

Device yang diuji: Xiaomi `25098RA98G`, Android **16 (SDK 36)**, root **SukiSU Ultra / KernelSU** (`ksud 4.1.3`), interception target **Burp Suite**.

---

## 1. Masalah

Setelah install Burp CA lewat Settings + pakai module "trust all cert", hanya sebagian trafik HTTPS ke-intercept (Google `200 OK`), sisanya gagal / "no internet". Cert **kelihatannya** sudah dipercaya, tapi mayoritas app gagal TLS handshake.

## 2. Akar masalah — trust store pindah ke APEX Conscrypt

Sejak **Android 14 (API 34)**, Google memindahkan **system CA trust store** agar bisa di-update lewat **Conscrypt APEX module** (`com.android.conscrypt`). Konsekuensinya:

| Lokasi | Android ≤13 | Android 14+ (device ini) |
|---|---|---|
| Store yang **dibaca app** | `/system/etc/security/cacerts/` | **`/apex/com.android.conscrypt/cacerts/`** |
| Menambah cert | `cp` file (remount rw) → beres | ❌ folder **read-only** (APEX bertanda tangan) |

Bukti diagnosa di device:

```
Burp CA di /data/misc/user/0/cacerts-added/   -> ADA (user store, dari Settings)
Burp CA di /system/etc/security/cacerts/      -> ADA (module lama menaruh di sini)
Burp CA di /apex/com.android.conscrypt/cacerts/ -> KOSONG   <-- INI MASALAHNYA
```

Module "trust all cert" gaya lama menaruh cert ke `/system/etc/...` — lokasi yang **sudah diabaikan** di Android 14+. Karena app membaca dari APEX (yang tidak berisi Burp CA), handshake ditolak.

## 3. Kenapa tidak bisa "sekadar copy file"

Folder `/apex/com.android.conscrypt/cacerts/` di-mount **read-only** dan di-backing oleh APEX yang ditandatangani. `cp` ke sana = `Read-only file system`. Satu-satunya cara menambah cert adalah **menimpa tampilan (overlay)** folder itu dengan folder lain yang berisi `cert sistem asli + Burp CA`, memakai **bind mount** — bukan menulis ke disk.

## 4. Teknik yang dipakai

Alur inti (identik untuk runtime maupun module):

```
1. Snapshot cert sistem asli dari /apex/com.android.conscrypt/cacerts (mis. 143 cert)
2. mount -t tmpfs di atas /system/etc/security/cacerts   (jadi dir tulis di RAM)
3. isi ulang: 143 cert asli + 1 Burp CA  -> total 144
   set owner root:root, mode 644,
   chcon u:object_r:system_security_cacerts_file:s0   (WAJIB, biar app boleh baca)
4. mount -o bind /system/etc/security/cacerts  ->  /apex/com.android.conscrypt/cacerts
```

Semuanya **tmpfs/bind = di RAM**, sehingga **reversible total** (hilang saat reboot / module di-disable). Tidak ada partisi disentuh → **tidak bisa brick**.

## 5. Temuan penting — kenapa harus SEBELUM zygote (bukan runtime)

Saat mencoba menyuntik ke namespace **zygote yang sudah berjalan** (`nsenter -t <zygote> -m -- mount ...`):

- Namespace zygote sendiri: `apex=144` ✅ (Burp ada)
- **Tapi app yang baru di-fork tetap `apex=143`** ❌ (Burp tidak diwarisi)

Penyebab: Android men-spawn app lewat **fork + specialization** (dengan **USAP pool** pre-fork dan setup **per-app mount namespace**). Menambah mount ke namespace zygote yang **sudah hidup** tidak turun konsisten ke app hasil specialization.

**Solusi:** lakukan bind mount di namespace **init/global SEBELUM zygote dibuat**, yaitu pada tahap **`post-fs-data`**. Karena mount sudah menjadi bagian **base namespace**, **setiap** app yang di-fork zygote mewarisinya otomatis — termasuk app yang diinstall di kemudian hari. Tidak perlu daemon, tidak perlu inject per-spawn, tidak ada race condition.

> Catatan: pendekatan "inject tiap app spawn" via watcher **ditolak** karena (a) rawan telat/race sebelum conscrypt cache trust store, (b) boros CPU/baterai, (c) berisiko menyentuh proses sistem (pernah bikin `system_server` freeze saat loop ke semua PID).

## 6. Implementasi module (SukiSU/KernelSU)

Struktur:

```
apex_burp_ca_module.zip
├── module.prop
├── post-fs-data.sh      # jalan sebelum zygote -> inject
└── certs/9a5ba575.0     # Burp/PortSwigger CA (DER), nama = subject hash
```

`post-fs-data.sh` menambahkan **guard** menunggu `/apex` siap (menghindari race timing boot) lalu menjalankan alur bagian 4, dan menulis `certfix.log` untuk verifikasi.

## 7. Verifikasi (setelah reboot)

`/data/adb/modules/apex_burp_ca/certfix.log`:

```
apex ready after 0x100ms, apex_count=143
legacy tmpfs count=144
apex after bind=144
=== done ===
```

Bukti **inheritance** (paling penting) — proses yang lahir fresh saat boot sudah trust Burp:

```
zygote64: apex trust store berisi Burp CA
systemui : apex trust store berisi 9a5ba575.0  (Burp)  <-- semua app inherit
```

End-to-end: **Chrome** dan app target **`land.lifeoasis.maum`** ke-intercept di Burp tanpa error sertifikat.

## 8. Yang TIDAK bisa diselesaikan teknik ini

**Certificate pinning.** App yang pinning (banking/e-wallet: BCA, CIMB, DANA, dll) hanya menerima cert spesifik miliknya, bukan trust store sistem. Teknik CA store apa pun tidak menembusnya. Solusi: **Frida / objection unpinning** di level runtime app (di luar cakupan dokumen ini).

## 9. Operasional harian

- **Cert**: otomatis tiap boot via module — zero maintenance, berlaku semua app.
- **Proxy**: tetap harus di-set manual (IP USB-LAN berubah-ubah). Cert ≠ proxy: cert bikin app *percaya*, proxy *mengarahkan* trafik ke Burp. Keduanya wajib untuk intercept.
- **Rollback**: SukiSU Manager → disable/hapus module → reboot. Balik bersih (tidak mungkin bootloop; jika script gagal, boot tetap lanjut tanpa cert).

---

## 10. Referensi

1. **HTTP Toolkit — "Android 14 blocks all methods to install system CA certificates"** (Tim Perry).
   Sumber praktis utama teknik tmpfs + bind + injeksi mount-namespace zygote. `httptoolkit.com/blog/android-14-install-system-ca-certificate/`
2. **AOSP — Conscrypt APEX (`com.android.conscrypt`)**. Android 14 menjadikan CA store updatable lewat APEX module; direktori runtime CA disajikan melalui conscrypt. `source.android.com` / `android.googlesource.com/platform/external/conscrypt`
3. **Conscrypt `TrustedCertificateStore`** — implementasi pembacaan CA berbasis direktori (lookup by subject hash `<hash>.<n>`, format PEM/DER). `android.googlesource.com/platform/external/conscrypt`
4. **KernelSU / SukiSU — Module Guide** (urutan eksekusi `post-fs-data.sh` sebelum zygote, format module). `kernelsu.org/guide/module.html`
5. **PortSwigger — Installing Burp's CA certificate in an Android device**. `portswigger.net/burp/documentation/desktop/mobile/config-android-device`
6. **Android platform_certificates / conscrypt cacerts change (API 34)** — commit yang memindahkan trust store ke jalur APEX.

> Verifikasi ulang URL sebelum dikutip di laporan formal; struktur path bisa berubah antar rilis Android.

---

*Ditulis untuk setup pentest VxU — Xiaomi 25098RA98G, Android 16, SukiSU Ultra.*
