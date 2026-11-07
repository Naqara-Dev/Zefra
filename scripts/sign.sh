#!/bin/bash
# Signs a built Zefra.app: nested code first, the app last. Developer ID when DEVELOPER_ID is set,
# otherwise the "Naqara Dev Code Signing" certificate, otherwise Apple Development.
set -euo pipefail
APP="$1"
IDENTITY="${DEVELOPER_ID:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-certificate -c "Naqara Dev Code Signing" >/dev/null 2>&1; then
    IDENTITY="Naqara Dev Code Signing"
  else
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
  fi
fi
if [[ -z "$IDENTITY" ]]; then
  echo "! No signing certificate: the app runs, but the fan helper refuses to start unsigned."
  exit 0
fi
TIMESTAMP="--timestamp=none"
[[ -n "${DEVELOPER_ID:-}" ]] && TIMESTAMP="--timestamp"
sign() { codesign --force --sign "$IDENTITY" "$TIMESTAMP" --options runtime --preserve-metadata=identifier,entitlements "$1" 2>/dev/null; }
find "$APP/Contents/Frameworks" -depth \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" -o -name "*.dylib" -o \( -name Autoupdate -type f \) \) -print0 2>/dev/null |
  while IFS= read -r -d '' code; do sign "$code"; done
codesign --force --sign "$IDENTITY" "$TIMESTAMP" --options runtime --identifier com.naqara.zefra.helper "$APP/Contents/MacOS/zefrad" 2>/dev/null
# A certificate with no team can't pass library validation, so without Developer ID the app couldn't
# load Sparkle. Developer ID builds keep it on.
ENTITLEMENTS=$(mktemp)
cp Config/Zefra.entitlements "$ENTITLEMENTS"
if [[ -z "${DEVELOPER_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
codesign --force --sign "$IDENTITY" "$TIMESTAMP" --options runtime --entitlements "$ENTITLEMENTS" "$APP" 2>/dev/null
rm -f "$ENTITLEMENTS"
codesign --verify --strict "$APP"
echo "✓ $APP, signed with \"$IDENTITY\""
