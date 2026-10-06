#!/bin/sh
# Signs BINARY with a signing identity that is made one time and then kept.
# Usage: dist/sign-macos.sh BINARY. Exit 0: signed. Exit 3: signed, and the identity is new.
#
# macOS ties a permission (Full Disk Access) to the signature of a program. The linker signs
# each build with its hash, so each build is a new program for macOS: the permission is gone
# and macOS asks again, folder by folder. A fixed identity keeps the permission across builds.
#
# The identity is a self-signed certificate in its own keychain file. The login keychain is not
# used, so macOS shows no dialog. The password is not a secret: the file mode protects the key,
# as it protects the config file. Any program that runs as this user can sign with it.
set -eu

bin=$1
dir=$HOME/.config/dirsized
keychain=$dir/signing.keychain-db
name="dirsized local signing"
pass=dirsized
new=0

if [ ! -f "$keychain" ]; then
    tmp=$(mktemp -d)
    # A keychain that is not complete must not stay: the next run would use it.
    trap 'rm -rf "$tmp"; [ "$new" -eq 1 ] || rm -f "$keychain"' EXIT
    mkdir -p "$dir"
    # The system openssl (LibreSSL) writes a PKCS#12 file that `security import` can read.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=$name" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -out "$tmp/id.p12" -passout "pass:$pass"
    security create-keychain -p "$pass" "$keychain"
    security import "$tmp/id.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$pass" "$keychain" >/dev/null
    chmod 600 "$keychain"
    new=1
fi

security unlock-keychain -p "$pass" "$keychain"
codesign --force --keychain "$keychain" --sign "$name" --identifier local.dirsized "$bin" 2>/dev/null
[ "$new" -eq 0 ] || exit 3
