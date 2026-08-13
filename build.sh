#!/bin/bash
# Regenerates the Xcode project, builds Aether-Courier, and installs the bundle
# to ~/Applications/Aether-Courier.app.
#
# Requires full Xcode + `brew install xcodegen`. Build output is routed OUTSIDE
# the (iCloud-synced) Projects dir to avoid the ".build" disk-I/O corruption
# that bites Swift builds under iCloud.
#
# STABLE SIGNING: local builds are normally ad-hoc signed, whose signature
# changes every build — so macOS re-prompts for Keychain access (mail passwords)
# and Calendar permission each time, because it treats each build as a new app.
# We instead sign with a persistent self-signed "Aether Courier Dev" certificate
# so those "Always Allow" grants stick across rebuilds. Set COURIER_NO_SIGN=1 to
# skip.
set -euo pipefail

cd "$(dirname "$0")"
DD="${COURIER_DERIVED_DATA:-$(mktemp -d)/courier-dd}"
APP_DEST="$HOME/Applications/Aether-Courier.app"
IDENTITY="Aether Courier Dev"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

ensure_identity() {
  # Self-signed codesigning certs don't appear in the codesigning-policy list,
  # so detect by certificate presence instead.
  if security find-certificate -c "$IDENTITY" "$LOGIN_KC" >/dev/null 2>&1; then
    return 0
  fi
  echo "→ Creating persistent self-signed code-signing certificate '$IDENTITY'…"
  local TMP PW; TMP="$(mktemp -d)"; PW="courierdev"
  cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" >/dev/null 2>&1
  # -legacy + a real password: Apple's `security` can't verify the MAC on an
  # OpenSSL-3 empty-password PKCS12.
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -out "$TMP/id.p12" -passout "pass:$PW" >/dev/null 2>&1
  security import "$TMP/id.p12" -k "$LOGIN_KC" -P "$PW" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1 || true
  rm -rf "$TMP"
  echo "  (You may be asked once to allow codesign to use the new key — click"
  echo "   'Always Allow'. After that, builds won't prompt again.)"
}

xcodegen generate
xcodebuild \
  -project Aether-Courier.xcodeproj \
  -scheme Aether-Courier \
  -destination 'platform=macOS' \
  -derivedDataPath "$DD" \
  ENABLE_DEBUG_DYLIB=NO \
  "${@:-build}"

BUILT="$DD/Build/Products/Debug/Aether-Courier.app"
if [ -d "$BUILT" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$APP_DEST"
  cp -R "$BUILT" "$APP_DEST"

  if [ "${COURIER_NO_SIGN:-0}" != "1" ]; then
    ensure_identity
    # Capture the generated entitlements so re-signing preserves sandbox/calendar.
    ENT="$(mktemp)"
    codesign -d --entitlements ":$ENT" "$APP_DEST" >/dev/null 2>&1 || true
    ENT_ARG=(); [ -s "$ENT" ] && ENT_ARG=(--entitlements "$ENT")
    # Sign nested code inner-first (frameworks/dylibs), then the app bundle, so
    # every Mach-O carries the same identity (dyld rejects mismatched Team IDs).
    while IFS= read -r -d '' f; do
      codesign --force --sign "$IDENTITY" "$f" >/dev/null 2>&1 || true
    done < <(find "$APP_DEST/Contents" \( -name "*.dylib" -o -name "*.framework" \) -print0 2>/dev/null)
    if codesign --force "${ENT_ARG[@]}" --sign "$IDENTITY" "$APP_DEST" >/dev/null 2>&1; then
      echo "✔ Signed with stable identity '$IDENTITY'"
    else
      echo "⚠ Stable signing failed — restoring ad-hoc signature."
      codesign --force --deep --sign - "$APP_DEST" >/dev/null 2>&1 || true
    fi
    rm -f "$ENT"
  fi

  echo "✔ Installed to $APP_DEST"
fi

echo "App: $APP_DEST"
