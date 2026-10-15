#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/
#
# Builds an unsigned Flameferret.ipa ready for SideStore, AltStore or Sideloadly.
# Usage (from the repo root, on a Mac with Xcode): ./scripts/flameferret-build-ipa.sh
# Set SKIP_BOOTSTRAP=1 to skip ./bootstrap.sh on repeat builds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/flameferret"
DERIVED="$ROOT/build/DerivedData"
cd "$ROOT"

if [ "${SKIP_BOOTSTRAP:-0}" != "1" ]; then
    ./bootstrap.sh firefox
fi

python3 scripts/flameferret-embed-js.py

mkdir -p "$ROOT/build"
cd firefox-ios
# Pins live in Package.resolved; resolving without -onlyUsePackageVersionsFromResolvedFile lets
# Xcode refresh the file's origin hash after Flameferret's added packages.
xcodebuild -resolvePackageDependencies \
    -project Client.xcodeproj \
    -scheme Fennec \
    -skipPackagePluginValidation

set +e
xcodebuild build \
    -project Client.xcodeproj \
    -scheme Fennec \
    -configuration Debug \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES="" \
    ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS=NO \
    DEBUG_INFORMATION_FORMAT=dwarf \
    > "$ROOT/build/xcodebuild.log" 2>&1
STATUS=$?
set -e

APP="$DERIVED/Build/Products/Debug-iphoneos/Client.app"
if [ $STATUS -ne 0 ] || [ ! -d "$APP" ]; then
    echo "Build failed; full log in build/xcodebuild.log" >&2
    grep -E "error:" "$ROOT/build/xcodebuild.log" | sort -u | head -60 >&2 || true
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/Flameferret.app"
APPDIR="$OUT/Payload/Flameferret.app"

# Free Apple IDs can only register a few App IDs, so drop the widget/share/notification extensions.
rm -rf "$APPDIR/PlugIns" "$APPDIR/Extensions"

# Debug-only test databases aren't needed on a phone.
rm -rf "$APPDIR/test-fixtures"

# Strip local and debug symbols to keep the IPA small enough to download from GitHub.
if command -v xcrun >/dev/null; then
    find "$APPDIR" -type f \( -perm -u+x -o -name "*.dylib" \) -print0 | while IFS= read -r -d '' binary; do
        if file "$binary" | grep -q "Mach-O"; then
            xcrun strip -x "$binary" 2>/dev/null || true
        fi
    done
fi

# Ad-hoc sign so the sideloading tool can read the app group it needs to register.
if command -v codesign >/dev/null; then
    find "$APPDIR/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) -print0 2>/dev/null \
        | xargs -0 -I{} codesign --force --sign - --timestamp=none {} || true
    codesign --force --sign - --timestamp=none \
        --entitlements "$ROOT/firefox-ios/Client/Entitlements/FlameferretSideload.entitlements" "$APPDIR"
fi

(cd "$OUT" && rm -f Flameferret.ipa && zip -qry -9 Flameferret.ipa Payload)
echo "Built $OUT/Flameferret.ipa"
