#!/usr/bin/env python3
"""
make_custom_ca.py - generate a custom-named CA for stealthy Burp interception.

WHY: Burp's default CA is named "PortSwigger CA". Hardened / anti-tamper apps scan the
device trust store for known interception-tool names and bail out if they see one. This
tool generates YOUR OWN CA with a neutral subject (e.g. "Internal Root CA") that Burp can
sign with, so the trust-store entry looks innocuous.

IMPORTANT (crypto reality): you cannot just rename Burp's exported cacert.der - the name
lives *inside* the signed certificate, and changing it needs the CA private key. So this
tool GENERATES A NEW CA (new key + cert). To actually use it you must import the generated
.p12 into Burp ONCE (Burp does the signing). The cacert.der you drop in ./in is only read
for DETECTION (to show what you're replacing) - it is never modified.

FLOW:
    [generate custom CA]  ->  [import .p12 into Burp, once]  ->  [install public cert on device]

OUTPUTS (in ./out):
    custom_ca.p12   -> import into Burp (Proxy > Proxy settings > Import/export CA cert
                       > "Certificate and private key in PKCS#12")
    custom_ca.pem   -> paste into the module WebUI (Certs > Import)
    <hash>.0        -> DER named by Android subject_hash_old (drop into module-source/certs/)
    custom_ca.der   -> raw public cert (backup)
    custom_ca.key   -> PRIVATE KEY (secret! never commit / never put on the device)

Requires: pip install cryptography

For AUTHORIZED security testing only.
"""
import argparse
import datetime
import hashlib
import os
import struct
import sys
import warnings

try:
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa, ec
    from cryptography.hazmat.primitives.serialization import (
        pkcs12, BestAvailableEncryption, NoEncryption, Encoding, PrivateFormat,
    )
except ImportError:
    sys.exit("ERROR: missing dependency. Run:  pip install cryptography")

# Names that anti-tamper apps look for in the trust store (subject/issuer CN).
MITM_NAMES = [
    "portswigger", "burp", "charles", "fiddler", "mitmproxy", "owasp", "zap",
    "http toolkit", "httptoolkit", "reqable", "proxyman", "httpcanary", "packet capture",
]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def flagged_name(*names):
    for n in names:
        if not n:
            continue
        low = n.lower()
        for sig in MITM_NAMES:
            if sig in low:
                return sig
    return None


def subject_hash_old(cert) -> str:
    """Replicate `openssl x509 -subject_hash_old`: MD5 of the subject Name DER,
    first 4 bytes little-endian, printed as 8 lowercase hex digits."""
    try:
        subj_der = cert.subject.public_bytes()
    except TypeError:
        from cryptography.hazmat.backends import default_backend
        subj_der = cert.subject.public_bytes(default_backend())
    digest = hashlib.md5(subj_der).digest()
    val = struct.unpack("<I", digest[:4])[0]
    return f"{val:08x}"


def cn_of(cert) -> str:
    try:
        return cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
    except IndexError:
        return "(no CN)"


def detect_inputs(in_dir):
    """Read any cert files in ./in and print their identity (detection only)."""
    if not os.path.isdir(in_dir):
        return
    found = False
    for fn in sorted(os.listdir(in_dir)):
        path = os.path.join(in_dir, fn)
        if not os.path.isfile(path) or fn.lower().endswith(".md"):
            continue
        try:
            data = open(path, "rb").read()
            with warnings.catch_warnings():   # 3rd-party certs may trip attribute-length checks
                warnings.simplefilter("ignore")
                try:
                    cert = x509.load_der_x509_certificate(data)
                except ValueError:
                    cert = x509.load_pem_x509_certificate(data)
                found = True
                cn = cn_of(cert)
                fp = hashlib.sha256(cert.public_bytes(Encoding.DER)).hexdigest()
                sh = subject_hash_old(cert)
        except Exception:
            continue
        hit = flagged_name(cn)
        print(f"  detected: {fn}")
        print(f"    subject CN     : {cn}")
        print(f"    subject_hash_old: {sh}")
        print(f"    SHA-256        : {fp}")
        if hit:
            print(f"    [!] STEALTH RISK : name contains \"{hit}\" - anti-tamper apps flag this. "
                  f"That's what the custom CA below replaces.")
        print()
    if not found:
        print("  (no cert found in ./in - skipping detection; generating a fresh CA)\n")


def build_ca(cn, org, ou, country, days, key_type):
    if key_type == "ec":
        key = ec.generate_private_key(ec.SECP256R1())
    else:
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pub = key.public_key()

    attrs = [x509.NameAttribute(NameOID.COMMON_NAME, cn)]
    if org:
        attrs.append(x509.NameAttribute(NameOID.ORGANIZATION_NAME, org))
    if ou:
        attrs.append(x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, ou))
    if country:
        attrs.append(x509.NameAttribute(NameOID.COUNTRY_NAME, country))
    name = x509.Name(attrs)

    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(pub)
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=days))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True, key_cert_sign=True, crl_sign=True,
                content_commitment=False, key_encipherment=False, data_encipherment=False,
                key_agreement=False, encipher_only=False, decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(pub), critical=False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(pub), critical=False)
        .sign(key, hashes.SHA256())
    )
    return key, cert


def main():
    ap = argparse.ArgumentParser(description="Generate a custom-named CA for stealthy Burp interception.")
    ap.add_argument("--cn", help='Subject Common Name (e.g. "Internal Root CA"). Prompted if omitted.')
    ap.add_argument("--org", default="", help="Organization (O), optional")
    ap.add_argument("--ou", default="", help="Organizational Unit (OU), optional")
    ap.add_argument("--country", default="", help="Country code (C), 2 letters, optional")
    ap.add_argument("--days", type=int, default=3650, help="Validity in days (default 3650)")
    ap.add_argument("--key", choices=["rsa", "ec"], default="rsa", help="Key type (default rsa 2048)")
    ap.add_argument("--in", dest="in_dir", default=os.path.join(SCRIPT_DIR, "custom_ca", "in"),
                    help="Input folder scanned for cacert.der (detection only)")
    ap.add_argument("--out", dest="out_dir", default=os.path.join(SCRIPT_DIR, "custom_ca", "out"),
                    help="Output folder for the generated CA")
    ap.add_argument("--p12-pass", default="burp", help='PKCS#12 password for Burp import (default "burp")')
    ap.add_argument("--name", default="custom_ca", help="Base filename for outputs (default custom_ca)")
    ap.add_argument("--install", action="store_true",
                    help="Also copy <hash>.0 into module-source/certs/ (then rebuild the zip)")
    args = ap.parse_args()

    print("=== make_custom_ca - custom CA for stealthy Burp interception ===\n")
    print(f"[1/4] Detecting existing cert(s) in: {args.in_dir}")
    os.makedirs(args.in_dir, exist_ok=True)
    detect_inputs(args.in_dir)

    cn = args.cn
    if not cn:
        try:
            cn = input('[2/4] Custom subject CN [Internal Root CA]: ').strip() or "Internal Root CA"
        except EOFError:
            cn = "Internal Root CA"
    hit = flagged_name(cn, args.org)
    if hit:
        print(f'  [!] WARNING: your chosen name contains "{hit}" - that defeats the point (still flagged).')
    print(f"[2/4] Generating {args.key.upper()} CA  CN=\"{cn}\"  days={args.days}\n")

    key, cert = build_ca(cn, args.org, args.ou, args.country, args.days, args.key)
    h = subject_hash_old(cert)
    fp = hashlib.sha256(cert.public_bytes(Encoding.DER)).hexdigest()

    os.makedirs(args.out_dir, exist_ok=True)
    base = os.path.join(args.out_dir, args.name)
    der = cert.public_bytes(Encoding.DER)

    # write outputs
    open(base + ".der", "wb").write(der)
    open(base + ".pem", "wb").write(cert.public_bytes(Encoding.PEM))
    open(os.path.join(args.out_dir, h + ".0"), "wb").write(der)
    open(base + ".key", "wb").write(
        key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    )
    enc = BestAvailableEncryption(args.p12_pass.encode()) if args.p12_pass else NoEncryption()
    p12 = pkcs12.serialize_key_and_certificates(
        name=args.name.encode(), key=key, cert=cert, cas=None, encryption_algorithm=enc
    )
    open(base + ".p12", "wb").write(p12)

    print("[3/4] Written to:", args.out_dir)
    print(f"    {args.name}.p12   (cert+key)  -> import into Burp   [password: {args.p12_pass or '(none)'}]")
    print(f"    {args.name}.pem              -> paste into WebUI (Certs > Import)")
    print(f"    {h}.0            -> Android trust-store name (module-source/certs/)")
    print(f"    {args.name}.der / {args.name}.key (backup / SECRET private key)")
    print()
    print("    subject CN      :", cn)
    print("    subject_hash_old:", h)
    print("    SHA-256         :", fp)
    print()

    if args.install:
        certs_dir = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "module-source", "certs"))
        os.makedirs(certs_dir, exist_ok=True)
        dst = os.path.join(certs_dir, h + ".0")
        open(dst, "wb").write(der)
        print(f"[4/4] Installed into module: {dst}")
        print("      Rebuild the zip:  bash module-source/build_mod.sh\n")
    else:
        print("[4/4] Not installed into the module (run with --install to auto-copy + rebuild).\n")

    p12_path = base + ".p12"
    pem_path = base + ".pem"
    hash0 = h + ".0"
    pw = args.p12_pass or "(none)"
    bar = "=" * 64
    print(bar)
    print("NEXT STEPS  (flow: generate -> sign in Burp -> trust on device -> reboot)")
    print(bar)
    print()
    print("STEP 1 - Load THIS CA into Burp so Burp signs traffic with it")
    print("  Burp menu: Proxy  ->  Proxy settings  ->  scroll to 'Import / export CA")
    print("  certificate' (or open the 'CA Certificate' dialog).")
    print("  In that dialog choose the IMPORT section (NOT Export):")
    print("      (o) Import  ->  \"Certificate and private key from PKCS#12 keystore\"")
    print("  Then:")
    print("    a. Click Next / Choose file.")
    print(f"    b. Select:   {p12_path}")
    print(f"    c. Password: {pw}")
    print("    d. Finish. Burp now issues site certs signed by YOUR CA:")
    print(f"       \"{cn}\"  (not 'PortSwigger CA').")
    print("  NOTE: pick the IMPORT 'from PKCS#12 keystore' option - the Export one just")
    print("        dumps Burp's current CA and does NOT load yours.")
    print()
    print("STEP 2 - Trust the PUBLIC cert on the device (pick ONE)")
    print("  A) Fastest - via the module WebUI:")
    print("       WebUI -> Certs tab -> Import -> paste the contents of:")
    print(f"         {pem_path}")
    print("       (open that .pem in a text editor and copy the whole -----BEGIN...-----).")
    print("  B) Bundle into the module:")
    print(f"       copy   {hash0}   into   module-source/certs/")
    print("       then:  bash module-source/build_mod.sh   -> reflash the zip.")
    if args.install:
        print("       (already auto-copied for you via --install; just rebuild + reflash.)")
    print()
    print("STEP 3 - Reboot the device")
    print("  So every app inherits the new trust store (baseline rebuilds cleanly).")
    print()
    print("STEP 4 - Verify")
    print("  - Set the device proxy to your Burp listener.")
    print("  - Open Chrome or a non-pinned app -> traffic should decrypt in Burp with no")
    print("    certificate error.")
    print("  - WebUI -> Verify tab -> pick the app -> Check -> expect \"Trusts your CA\".")
    print(f"  - In the trust store the entry now reads \"{cn}\" - neutral, not flagged.")
    print()
    print(bar)
    print("SECURITY")
    print(f"  KEEP SECRET (never on device / never commit):  {args.name}.p12 , {args.name}.key")
    print(f"  Safe to put on device:                         {args.name}.pem , {args.name}.der , {hash0}")
    print("  Authorized testing only.")
    print(bar)


if __name__ == "__main__":
    main()
