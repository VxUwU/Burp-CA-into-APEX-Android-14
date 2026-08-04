#!/system/bin/sh
# Runtime per-app CA injection (fallback / tanpa reboot).
# Pakai kalau butuh cepat tanpa module, atau untuk app yang sudah jalan.
# Jalankan dengan: su -mm -c 'sh inject_app_runtime.sh <package_name>'
#
# CATATAN: metode andal di Android 14+ adalah MODULE post-fs-data (lihat ../module-source).
# Script ini menyuntik langsung ke namespace proses app target (aman: TIDAK loop semua PID).

PKG="$1"
[ -z "$PKG" ] && { echo "usage: sh $0 <package_name>"; exit 1; }

LEGACY=/system/etc/security/cacerts
APEX=/apex/com.android.conscrypt/cacerts
CERT_SRC=/data/misc/user/0/cacerts-added   # sumber Burp CA (dari Settings)

# 1. Siapkan legacy tmpfs berisi cert sistem + Burp (kalau belum ada Burp di dalamnya)
if [ "$(ls $APEX | wc -l)" -lt "$(ls $LEGACY 2>/dev/null | wc -l)" ] || ! ls $APEX/9a5ba575.0 >/dev/null 2>&1; then
  TMP=/dev/.ca_snap; rm -rf $TMP; mkdir -p $TMP
  cp $APEX/* $TMP/ 2>/dev/null
  mount -t tmpfs tmpfs $LEGACY 2>/dev/null
  cp $TMP/* $LEGACY/ 2>/dev/null
  cp $CERT_SRC/* $LEGACY/ 2>/dev/null
  chown 0:0 $LEGACY/* 2>/dev/null; chmod 644 $LEGACY/* 2>/dev/null
  chcon u:object_r:system_security_cacerts_file:s0 $LEGACY/* 2>/dev/null
  rm -rf $TMP
fi
echo "legacy store: $(ls $LEGACY | wc -l) cert"

# 2. Inject ke SEMUA proses milik package target (hanya app itu, bukan proses sistem)
PIDS=$(pidof "$PKG")
[ -z "$PIDS" ] && { echo "app $PKG belum jalan. Buka dulu app-nya lalu ulangi."; exit 1; }
for P in $PIDS; do
  nsenter -t $P -m -- mount -o bind $LEGACY $APEX 2>/dev/null && echo "  injected -> $P"
done

# 3. Verifikasi
for P in $PIDS; do
  N=$(nsenter -t $P -m -- ls $APEX 2>/dev/null | wc -l)
  B=$(nsenter -t $P -m -- ls $APEX/9a5ba575.0 2>/dev/null)
  echo "$PKG $P -> apex=$N burp=[$B]"
done
echo "Selesai. Reload/aktifkan koneksi di app untuk memakai trust store baru."
