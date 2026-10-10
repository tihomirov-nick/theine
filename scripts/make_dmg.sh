#!/bin/bash
# Builds the app and packs it into dist/Theine-<version>.dmg with the install notes from docs/.
#   VERSION=1.0.0 ./scripts/make_dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.0.1}"
export VERSION
# Release builds are signed with the family's self-signed certificate "tihomirov-nick": installed copies update
# themselves only to a version signed by the same certificate. Without it the build is signed ad-hoc and the copies
# installed from this DMG will never update. Release builds go to build/release, so the local build/Theine.app stays.
CERT_SHA1="AF82036140843A7D76497EA8E4CD23403C8AEDC2"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_SHA1"; then
        SIGN_IDENTITY="$CERT_SHA1"
    else
        SIGN_IDENTITY="-"
        echo "!!! The certificate \"tihomirov-nick\" is not in the keychain: signing ad-hoc." >&2
        echo "!!! Copies installed from this DMG cannot update themselves, and the next releases will not install over them." >&2
    fi
fi
export SIGN_IDENTITY
export OUT_DIR="$ROOT/build/release"

./scripts/build_app.sh

STAGE="$ROOT/build/dmg"
DMG="$ROOT/dist/Theine-$VERSION.dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$ROOT/dist"
cp -R "$OUT_DIR/Theine.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/Как установить.txt" "$ROOT/docs/How to install.txt" "$STAGE/"

rm -f "$DMG"
echo "==> creating $DMG"
hdiutil create -volname "Theine $VERSION" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
if [ "${SIGN_IDENTITY:--}" != "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null && echo "==> verified"
echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
