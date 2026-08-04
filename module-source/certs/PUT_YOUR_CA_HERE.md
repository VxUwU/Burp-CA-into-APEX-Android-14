# Put your CA certificate here

This folder must contain **your own** CA certificate (e.g. exported from Burp Suite),
in **DER** format, named by its Android subject hash: `<hash>.0`.

```bash
# Export your Burp CA in DER format from:
#   Burp > Proxy > Proxy settings > TLS > Export > Certificate in DER format
# Then compute the hash name and copy it in:
HASH=$(openssl x509 -inform DER -in cacert.der -subject_hash_old -noout)
cp cacert.der "$HASH.0"
```

Only the **public** certificate belongs here — never the private key.
This repo intentionally ships **no** CA so you always trust your own, not someone else's.
