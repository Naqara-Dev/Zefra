#!/bin/bash
# Builds Zefra and signs the app, its frameworks and its helper with one certificate, because the
# helper only takes calls from an app signed like itself. ./scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
xcodebuild -project Zefra.xcodeproj -scheme Zefra -configuration "$CONFIG" -derivedDataPath build \
  -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" -quiet "${@:2}"
APP="build/Build/Products/$CONFIG/Zefra.app"
./scripts/sign.sh "$APP"
