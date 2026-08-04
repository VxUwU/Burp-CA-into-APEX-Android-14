#!/system/bin/sh
# Runs at post-fs-data (BEFORE zygote) so every app inherits the trust store.
MODDIR=${0%/*}
LEGACY=/system/etc/security/cacerts
APEX=/apex/com.android.conscrypt/cacerts
LOG=$MODDIR/certfix.log

echo "=== $(date) post-fs-data start ===" > $LOG

# 1. Wait until APEX conscrypt cacerts is populated (timing guard, max ~10s)
i=0
while [ -z "$(ls -A $APEX 2>/dev/null)" ]; do
  i=$((i+1)); [ $i -ge 100 ] && break
  sleep 0.1
done
echo "apex ready after ${i}x100ms, apex_count=$(ls $APEX 2>/dev/null | wc -l)" >> $LOG

# 2. Snapshot current APEX system CAs
TMP=/dev/.apex_ca_snap
rm -rf $TMP; mkdir -p $TMP
cp $APEX/* $TMP/ 2>/dev/null

# 3. tmpfs over legacy dir, refill with system CAs + bundled Burp cert
mount -t tmpfs tmpfs $LEGACY
cp $TMP/* $LEGACY/ 2>/dev/null
cp $MODDIR/certs/* $LEGACY/ 2>/dev/null
chown 0:0 $LEGACY/* 2>/dev/null
chmod 644 $LEGACY/* 2>/dev/null
chcon u:object_r:system_security_cacerts_file:s0 $LEGACY/* 2>/dev/null
echo "legacy tmpfs count=$(ls $LEGACY | wc -l)" >> $LOG

# 4. Bind the populated legacy dir over the read-only APEX dir
mount -o bind $LEGACY $APEX 2>>$LOG
echo "apex after bind=$(ls $APEX | wc -l)" >> $LOG

rm -rf $TMP
echo "=== done ===" >> $LOG
