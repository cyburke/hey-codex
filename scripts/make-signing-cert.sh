#!/usr/bin/env bash
# Creates the self-signed certificate that keeps users' permissions working
# across updates, and imports it into the login keychain.
#
# Why this exists: an ad-hoc signature's designated requirement is the binary's
# own hash, so macOS treats every rebuild as a different app and silently voids
# Microphone and Accessibility. A signature from a fixed certificate produces a
# requirement naming the bundle id and the certificate instead, which survives
# rebuilds. Gatekeeper trust is irrelevant here: the app is unnotarized either
# way and the Homebrew cask clears the quarantine flag.
#
# Run once. Keep the .p12 that lands in ~/.heycodex-signing somewhere safe and
# private: it is the only thing that keeps the requirement stable, and replacing
# it forces every existing user to grant both permissions again, once.
set -euo pipefail

NAME="Hey Codex Local Signing"
OUT="$HOME/.heycodex-signing"
PASS="${HEYCODEX_CERT_PASSWORD:-heycodex}"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Identity \"$NAME\" is already in the keychain. Nothing to do."
    exit 0
fi

mkdir -p "$OUT"
cd "$OUT"
cat > openssl.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Hey Codex Local Signing
O = Hey Codex
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    -days 3650 -nodes -config openssl.cnf >/dev/null 2>&1
# Legacy PKCS12 algorithms: macOS refuses OpenSSL 3's defaults on import.
openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 \
    -passout "pass:$PASS" -name "$NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1
security import identity.p12 -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security

echo "Imported \"$NAME\". Private key and certificate are in $OUT."
echo "Back up $OUT/identity.p12. Losing it costs every user one more re-grant."
security find-identity -p codesigning | grep "$NAME" || true
