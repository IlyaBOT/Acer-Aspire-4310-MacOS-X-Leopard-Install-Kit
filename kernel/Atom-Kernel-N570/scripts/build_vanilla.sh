#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOCK_FILE="$ROOT_DIR/SOURCE.lock"
SRC_DIR="$ROOT_DIR/src/xnu"
WORK_DIR="$ROOT_DIR/work/vanilla"
ARTIFACT_DIR="$ROOT_DIR/artifacts/vanilla"
SDKROOT="${SDKROOT:-/Developer/SDKs/MacOSX10.6.sdk}"

# shellcheck disable=SC1090
. "$LOCK_FILE"

log() { printf '[atom-kernel-build] %s\n' "$*"; }
die() { printf '[atom-kernel-build] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname -s)" = Darwin ] || die "vanilla reference build must run on macOS"
case "$(sw_vers -productVersion 2>/dev/null || true)" in
  10.6*) ;;
  *) die "expected Mac OS X 10.6.x for the reference build" ;;
esac

have make || die "make is required"
have gcc || true
[ -x /Developer/usr/bin/gcc-4.2 ] || die "Xcode 3.2 gcc-4.2 not found at /Developer/usr/bin/gcc-4.2"
[ -d "$SDKROOT" ] || die "Snow Leopard SDK not found: $SDKROOT"
[ -f "$SRC_DIR/.xnu-source-commit" ] || die "source not prepared; run scripts/bootstrap_source.sh"
[ "$(cat "$SRC_DIR/.xnu-source-commit")" = "$XNU_COMMIT" ] || die "source commit marker does not match SOURCE.lock"

if grep -R -F -q '[N570 ATOM-KERNEL]' "$SRC_DIR" 2>/dev/null; then
  die "N570 patch/debug prefix found in source; vanilla build must remain unmodified"
fi

rm -rf "$WORK_DIR" "$ARTIFACT_DIR"
mkdir -p "$WORK_DIR/obj" "$WORK_DIR/sym" "$WORK_DIR/dst" "$ARTIFACT_DIR"

export SRCROOT="$SRC_DIR"
export OBJROOT="$WORK_DIR/obj"
export SYMROOT="$WORK_DIR/sym"
export DSTROOT="$WORK_DIR/dst"
export SDKROOT
export BUILD_STABS=1

JOBS="${MAKEJOBS:-}"
if [ -z "$JOBS" ]; then
  if have sysctl; then
    NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  else
    NCPU=1
  fi
  [ "$NCPU" -ge 1 ] 2>/dev/null || NCPU=1
  JOBS="-j$NCPU"
fi

log "source: $SRC_DIR"
log "XNU: $XNU_VERSION ($XNU_COMMIT)"
log "SDK: $SDKROOT"
log "configuration: RELEASE I386"
log "MAKEJOBS: $JOBS"

cd "$SRC_DIR"
make \
  ARCH_CONFIGS=I386 \
  KERNEL_CONFIGS=RELEASE \
  SDKROOT="$SDKROOT" \
  OBJROOT="$OBJROOT" \
  SYMROOT="$SYMROOT" \
  DSTROOT="$DSTROOT" \
  MAKEJOBS="$JOBS" \
  exporthdrs all

KERNEL="$(find "$OBJROOT" "$SYMROOT" "$DSTROOT" -type f -name mach_kernel -print 2>/dev/null | head -1)"
[ -n "$KERNEL" ] || die "build completed but mach_kernel was not found"
cp -p "$KERNEL" "$ARTIFACT_DIR/mach_kernel"

KERNEL_SYS="$(find "$OBJROOT" "$SYMROOT" "$DSTROOT" -type f -name mach_kernel.sys -print 2>/dev/null | head -1)"
if [ -n "$KERNEL_SYS" ]; then
  cp -p "$KERNEL_SYS" "$ARTIFACT_DIR/mach_kernel.sys"
  log "symbols: $ARTIFACT_DIR/mach_kernel.sys"
fi

DSYM="$(find "$OBJROOT" "$SYMROOT" "$DSTROOT" -type d -name 'mach_kernel.dSYM' -print 2>/dev/null | head -1)"
if [ -n "$DSYM" ]; then
  cp -R "$DSYM" "$ARTIFACT_DIR/"
  log "dSYM: $ARTIFACT_DIR/mach_kernel.dSYM"
fi

printf '%s\n' "$XNU_COMMIT" > "$ARTIFACT_DIR/source-commit.txt"
shasum -a 256 "$ARTIFACT_DIR/mach_kernel" > "$ARTIFACT_DIR/mach_kernel.sha256"

log "vanilla build complete: $ARTIFACT_DIR/mach_kernel"
cat "$ARTIFACT_DIR/mach_kernel.sha256"
log "next: $SCRIPT_DIR/test_vanilla.sh '$ARTIFACT_DIR/mach_kernel'"
