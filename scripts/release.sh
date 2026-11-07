#!/bin/bash
# Builds a release: dist/Zefra-X.dmg, dist/appcast.xml and Casks/zefra.rb. Publish the first two on a
# GitHub release of Naqara-Dev/Zefra; the app reads releases/latest/download/appcast.xml.
#
#   ./scripts/release.sh               Signed with the "Naqara Dev Code Signing" certificate. Gatekeeper
#                                      warns on first install; updates after that install in place.
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="zefra-notary" ./scripts/release.sh
#                                      Signed, notarized and stapled. Needs a paid Apple Developer account.
#
# Bump CURRENT_PROJECT_VERSION every release: Sparkle compares that build number. Change the helper?
# Bump HelperInfo.version too, so installed helpers get replaced.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' Zefra.xcodeproj/project.pbxproj | head -1)
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' Zefra.xcodeproj/project.pbxproj | head -1)
OUT=${OUT:-dist}
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin
DMG="$OUT/Zefra-$VERSION.dmg"
FEED_BASE=${FEED_BASE:-https://github.com/Naqara-Dev/Zefra/releases/download/v$VERSION}
rm -rf "$OUT" && mkdir -p "$OUT"

echo "› Testing"
./scripts/test.sh

echo "› Building Zefra $VERSION ($BUILD)"
./scripts/build.sh Release ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64'
APP=build/Build/Products/Release/Zefra.app
echo "  Architectures: $(lipo -archs "$APP/Contents/MacOS/Zefra")"

echo "› Creating $DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Zefra" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "› Notarizing (this takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  else
    echo "  NOTARY_PROFILE not set: signed but not notarized."
  fi
fi

echo "› Writing appcast.xml"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account naqara-zefra "$DMG")
cat > "$OUT/appcast.xml" <<FEED
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Zefra</title>
    <item>
      <title>Zefra $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <enclosure url="$FEED_BASE/Zefra-$VERSION.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
FEED

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
mkdir -p Casks
cat > Casks/zefra.rb <<CASK
cask "zefra" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/Naqara-Dev/Zefra/releases/download/v#{version}/Zefra-#{version}.dmg"
  name "Zefra"
  desc "Temperatures, fan control and hardware diagnostics"
  homepage "https://github.com/Naqara-Dev/Zefra"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Zefra.app"
  binary "#{appdir}/Zefra.app/Contents/MacOS/Zefra", target: "zefra"

  uninstall launchctl: "com.naqara.zefra.helper",
            delete:    [
              "/Library/LaunchDaemons/com.naqara.zefra.helper.plist",
              "/Library/PrivilegedHelperTools/com.naqara.zefra.helper",
            ]

  zap trash: [
    "~/Library/Application Support/Zefra",
    "~/Library/Preferences/com.naqara.zefra.plist",
  ]
end
CASK

echo "$SHA  $DMG"
echo "✓ $DMG"
echo "✓ $OUT/appcast.xml"
echo "✓ Casks/zefra.rb"
