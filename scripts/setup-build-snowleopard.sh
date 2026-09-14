#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PROJECT="$ROOT_DIR/drivers/sdhci-o2micro/VoodooSDHC.xcodeproj"
SDK_DIR="/Developer/SDKs/MacOSX10.6.sdk"
KERNEL_FRAMEWORK="/System/Library/Frameworks/Kernel.framework"

usage() {
  cat <<'EOF'
Check the Snow Leopard build host for the legacy SDHCI kext.

Expected host:
  Mac OS X 10.6.x
  Xcode 3.2.6
  MacOSX10.6.sdk
  Kernel.framework

This script is read-only.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
  ""|--check) ;;
  -h|--help) usage; exit 0 ;;
  *) die "unknown argument: $1" ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || die "run this on Mac OS X Snow Leopard"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found; install Xcode 3.2.6"

SW_VERSION="$(/usr/bin/sw_vers -productVersion)"
case "$SW_VERSION" in
  10.6.*) ;;
  *) die "expected Mac OS X 10.6.x, found $SW_VERSION" ;;
esac

XCODE_VERSION="$(xcodebuild -version 2>/dev/null | /usr/bin/head -1)"
case "$XCODE_VERSION" in
  "Xcode 3.2"*) ;;
  *) die "expected Xcode 3.2.x, found: $XCODE_VERSION" ;;
esac

SDK_LIST="$(xcodebuild -showsdks 2>&1 || true)"
case "$SDK_LIST" in
  *macosx10.6*|*"Mac OS X 10.6"*) ;;
  *) die "Mac OS X 10.6 SDK is not listed by xcodebuild" ;;
esac

[[ -d "$SDK_DIR" ]] || die "missing SDK: $SDK_DIR"
[[ -d "$KERNEL_FRAMEWORK" ]] || die "missing Kernel.framework: $KERNEL_FRAMEWORK"
[[ -f "$PROJECT/project.pbxproj" ]] || die "missing project: $PROJECT/project.pbxproj"

echo "Build host OK"
echo "  OS:      $SW_VERSION"
echo "  Xcode:   $XCODE_VERSION"
echo "  SDK:     $SDK_DIR"
echo "  Project: $PROJECT"
