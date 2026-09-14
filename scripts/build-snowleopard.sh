#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PROJECT="$ROOT_DIR/drivers/sdhci-o2micro/VoodooSDHC.xcodeproj"
OUTPUT_DIR="$ROOT_DIR/drivers/sdhci-o2micro/build"
CONFIGURATION="Debug"
CLEAN=0

usage() {
  cat <<'EOF'
Build the O2Micro diagnostic VoodooSDHC.kext on Snow Leopard.

Options:
  --configuration Debug|Release
  --output DIR
  --clean
  -h, --help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --configuration)
      (($# > 1)) || die "--configuration needs a value"
      CONFIGURATION="$2"; shift
      ;;
    --output)
      (($# > 1)) || die "--output needs a value"
      OUTPUT_DIR="$2"; shift
      ;;
    --clean) CLEAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

case "$CONFIGURATION" in
  Debug|Release) ;;
  *) die "configuration must be Debug or Release" ;;
esac

"$SCRIPT_DIR/setup-build-snowleopard.sh"
[[ -f "$PROJECT/project.pbxproj" ]] || die "project not found: $PROJECT/project.pbxproj"
mkdir -p "$OUTPUT_DIR"

if (( CLEAN )); then
  xcodebuild \
    -project "$PROJECT" \
    -target VoodooSDHC \
    -configuration "$CONFIGURATION" \
    -sdk macosx10.6 \
    clean
fi

xcodebuild \
  -project "$PROJECT" \
  -target VoodooSDHC \
  -configuration "$CONFIGURATION" \
  -arch i386 \
  -sdk macosx10.6 \
  SDKROOT=macosx10.6 \
  MACOSX_DEPLOYMENT_TARGET=10.6 \
  ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$OUTPUT_DIR" \
  build

KEXT="$OUTPUT_DIR/VoodooSDHC.kext"
[[ -d "$KEXT" ]] || die "build completed without $KEXT"
/usr/bin/plutil -lint "$KEXT/Contents/Info.plist"
echo "Built: $KEXT"
