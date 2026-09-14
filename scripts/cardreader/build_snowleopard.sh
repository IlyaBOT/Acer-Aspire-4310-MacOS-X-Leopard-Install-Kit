#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="${1:-$PWD}"
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
PROJECT_NAME="VoodooSDHC.xcodeproj"
PROJECT="$SOURCE_DIR/$PROJECT_NAME"
BUILD_DIR="$SOURCE_DIR/build-o2micro"

log() { printf '[cardreader-build] %s\n' "$*"; }
die() { printf '[cardreader-build] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "must run on Darwin"
[[ "$(uname -r | cut -d. -f1)" == "10" ]] || die "build this target on Snow Leopard / Darwin 10"
[[ -d "$SOURCE_DIR" ]] || die "missing source directory: $SOURCE_DIR"
[[ -f "$SOURCE_DIR/VoodooSDHC.cpp" ]] || die "missing VoodooSDHC.cpp"
[[ -f "$SOURCE_DIR/Info.plist" ]] || die "missing Info.plist"
[[ -f "$PROJECT/project.pbxproj" ]] || {
  printf '[cardreader-build] prepared tree is missing the Xcode project:\n' >&2
  printf '  %s\n' "$PROJECT/project.pbxproj" >&2
  printf '[cardreader-build] top-level source contents:\n' >&2
  ls -la "$SOURCE_DIR" >&2 || true
  die "rerun scripts/cardreader/prepare_o2micro_source.sh from the repository root"
}

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

log "xcodebuild: $XCODEBUILD"
log "source directory: $SOURCE_DIR"
log "project: $PROJECT_NAME"
log "building i386 KEXT with Xcode 3.2 toolchain"

# Xcode 3.2's xcodebuild is much more reliable when the project bundle is named
# relative to the current working directory.  In particular, some 3.2 builds
# reject an otherwise valid absolute -project path with the misleading error
# "the project ... does not exist in this directory".
(
  cd "$SOURCE_DIR"
  "$XCODEBUILD" \
    -project "$PROJECT_NAME" \
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
)

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
MATCH="$(/usr/libexec/PlistBuddy -c 'Print :IOKitPersonalities:SD\ Card\ Host\ Controller:IOPCIMatch' "$KEXT/Contents/Info.plist")"
printf '%s\n' "$MATCH"
printf '%s\n' "$MATCH" | grep -q '0x71201217' || die "built KEXT does not match O2Micro 1217:7120"

# Snow Leopard's kextutil validates ownership as well as linkage. Validate a
# disposable root-owned copy so subsequent builds can still clean BUILD_DIR.
# -n is important here: an older VoodooSDHC build may already be loaded, and a
# normal kextutil invocation would try to load the new UUID and fail even though
# the freshly built bundle itself is valid.
STAGE="/tmp/VoodooSDHC-o2micro-validate.kext"
sudo rm -rf "$STAGE"
sudo cp -R "$KEXT" "$STAGE"
sudo chown -R root:wheel "$STAGE"
sudo chmod -R 755 "$STAGE"
log "kextutil validation (no load)"
sudo kextutil -n -t -v 2 "$STAGE" || die "kextutil validation failed"
sudo rm -rf "$STAGE"

log "SUCCESS: $KEXT"
printf '%s\n' "$KEXT" > "$SOURCE_DIR/.last-built-kext"
