#!/bin/zsh
# Creates a self-signed code-signing identity in the login keychain.
#
# Ad-hoc signatures identify the app by its cdhash, which changes with every
# build, so macOS privacy grants (e.g. access to NetEase Cloud Music's data)
# are lost on each update. Signing every release with the same certificate
# keeps the designated requirement stable, so grants survive upgrades.
#
# Back up the identity (Keychain Access → export as .p12) — releases signed
# with a different certificate will lose users' privacy grants once more.
set -euo pipefail

name=${SIGN_IDENTITY:-"MusicRateSwitcher Self-Signed"}
keychain="$HOME/Library/Keychains/login.keychain-db"

# macOS only counts an identity as valid for code signing when the certificate
# is trusted for that purpose. An untrusted self-signed certificate reports
# CSSMERR_TP_NOT_TRUSTED, and checks that look for a valid identity then treat
# the app as unsigned.
trust_identity() {
    if security find-identity -v -p codesigning | grep -qF "$name"; then
        return 0
    fi
    local pem status
    pem=$(mktemp)
    if ! security find-certificate -c "$name" -p > "$pem" 2>/dev/null; then
        rm -f "$pem"
        return 1
    fi
    security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$pem" >/dev/null 2>&1
    status=$?
    rm -f "$pem"
    return $status
}

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
    echo "Signing identity \"$name\" already exists."
    trust_identity || echo "warning: could not set code-signing trust; mark \"$name\" as Always Trust in Keychain Access." >&2
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -config "$work/openssl.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
passphrase=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$name" -out "$work/identity.p12" -passout "pass:$passphrase"
security import "$work/identity.p12" -k "$keychain" -P "$passphrase" -T /usr/bin/codesign >/dev/null

trust_identity || echo "warning: could not set code-signing trust; mark \"$name\" as Always Trust in Keychain Access." >&2

echo "Created signing identity \"$name\"."
