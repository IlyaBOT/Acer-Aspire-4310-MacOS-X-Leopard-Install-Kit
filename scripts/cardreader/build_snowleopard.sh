#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="${1:-$PWD}"
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
PROJECT="$SOURCE_DIR/VoodooSDHC.xcodeproj"
BUILD_DIR="$SOURCE_DIR/build-o2micro"

log() { printf '[cardreader-build] %s\n' "$*"; }
die() { printf '[cardreader-build] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "must run on Darwin"
[[ "$(uname -r | cut -d. -f1)" == "10" ]] || die "build this target on Snow Leopard / Darwin 10"
[[ -d "$PROJECT" ]] || die "missing $PROJECT"
[[ -f "$SOURCE_DIR/VoodooSDHC.cpp" ]] || die "missing VoodooSDHC.cpp"
[[ -f "$SOURCE_DIR/Info.plist" ]] || die "missing Info.plist"

if command -v xcodebuild >/dev/null 2>&1; then
  XCODEBUILD="$(command -v xcodebuild)"
elif [[ -x /Developer/usr/bin/xcodebuild ]]; then
  XCODEBUILD=/Developer/usr/bin/xcodebuild
else
  die "xcodebuild is missing; install Xcode 3.2.x first"
fi

[[ -d /Developer/SDKs/MacOSX10.6.sdk ]] || die "MacOSX10.6.sdk is missing"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "building i386 KEXT with Xcode 3.2 toolchain"
"$XCODEBUILD" \
  -project "$PROJECT" \
  -target VoodooSDHC \
  -configuration Release \
  -sdk macosx10.6 \
  ARCHS=i386 \
  VALID_ARCHS=i386 \
  ONLY_ACTIVE_ARCH=YES \
  MACOSX_DEPLOYMENT_TARGET=10.6 \
  GCC_VERSION=4.2 \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  clean build

KEXT="$BUILD_DIR/VoodooSDHC.kext"
[[ -d "$KEXT" ]] || {
  KEXT="$(find "$BUILD_DIR" -type d -name 'VoodooSDHC.kext' -print | head -1)"
}
[[ -n "$KEXT" && -d "$KEXT" ]] || die "build completed but VoodooSDHC.kext was not found"
BIN="$KEXT/Contents/MacOS/VoodooSDHC"
[[ -f "$BIN" ]] || die "KEXT executable is missing: $BIN"

log "binary architecture"
file "$BIN"
file "$BIN" | grep -q 'i386' || die "built binary does not contain i386"

log "Info.plist"
plutil -lint "$KEXT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :IOKitPersonalities:SD Card Host Controller:IOPCIMatch' "$KEXT/Contents/Info.plist"

log "kextutil validation"
sudo chown -R root:wheel "$KEXT"
sudo chmod -R 755 "$KEXT"
sudo kextutil -t -v 2 "$KEXT" || die "kextutil validation failed"

log "SUCCESS: $KEXT"
printf '%s\n' "$KEXT" > "$SOURCE_DIR/.last-built-kext"
