#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOCK_FILE="$ROOT_DIR/SOURCE.lock"
SRC_DIR="$ROOT_DIR/src/xnu"
WORK_DIR="$ROOT_DIR/work/n570-release"
ARTIFACT_DIR="$ROOT_DIR/artifacts/n570-release"
BUILD_TOOLS_BIN="$ROOT_DIR/work/build-tools/bin"
SDKROOT="${SDKROOT:-/Developer/SDKs/MacOSX10.6.sdk}"

# shellcheck disable=SC1090
. "$LOCK_FILE"

log() { printf '[atom-kernel-release-build] %s\n' "$*"; }
die() { printf '[atom-kernel-release-build] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname -s)" = Darwin ] || die "reference build must run on macOS"
case "$(sw_vers -productVersion 2>/dev/null || true)" in
  10.6*) ;;
  *) die "expected Mac OS X 10.6.x for this historical reference build" ;;
esac

have make || die "make is required"
[ -x /Developer/usr/bin/gcc-4.2 ] || die "Xcode 3.2 gcc-4.2 not found at /Developer/usr/bin/gcc-4.2"
[ -d "$SDKROOT" ] || die "Snow Leopard SDK not found: $SDKROOT"
[ -f "$SRC_DIR/.xnu-source-commit" ] || die "source marker missing"
[ "$(cat "$SRC_DIR/.xnu-source-commit")" = "$XNU_COMMIT" ] || die "source commit marker mismatch"

grep -q 'CPUID_MODEL_ATOM' "$SRC_DIR/osfmk/i386/cpuid.h" || die "Atom model constant not found; apply scripts/apply_n570_atom_debug_patch.py first"
grep -q 'case CPUID_MODEL_ATOM:' "$SRC_DIR/osfmk/i386/cpuid.c" || die "Atom family case not found"
grep -F -q '[N570 ATOM-KERNEL]' "$SRC_DIR/osfmk/i386/i386_init.c" || die "N570 instrumentation markers not found"

if [ ! -x "$BUILD_TOOLS_BIN/relpath" ] || \
   [ ! -x "$BUILD_TOOLS_BIN/decomment" ] || \
   [ ! -x "$BUILD_TOOLS_BIN/setsegname" ] || \
   [ ! -x "$BUILD_TOOLS_BIN/kextsymboltool" ]; then
  log "Darwin build helpers missing; bootstrapping relpath/decomment/setsegname/kextsymboltool"
  bash "$SCRIPT_DIR/bootstrap_snowleopard_build_tools.sh"
fi
RELPATH_TOOL="$BUILD_TOOLS_BIN/relpath"
DECOMMENT_TOOL="$BUILD_TOOLS_BIN/decomment"
SETSEGNAME_TOOL="$BUILD_TOOLS_BIN/setsegname"
KEXTSYMBOLTOOL_TOOL="$BUILD_TOOLS_BIN/kextsymboltool"

if [ "${CLEAN_BUILD:-0}" = "1" ]; then
  log "CLEAN_BUILD=1: removing previous N570 RELEASE work tree"
  rm -rf "$WORK_DIR"
fi
rm -rf "$ARTIFACT_DIR"
mkdir -p "$WORK_DIR/obj" "$WORK_DIR/sym" "$WORK_DIR/dst" "$ARTIFACT_DIR"

export SRCROOT="$SRC_DIR"
export OBJROOT="$WORK_DIR/obj"
export SYMROOT="$WORK_DIR/sym"
export DSTROOT="$WORK_DIR/dst"
export SDKROOT
export BUILD_STABS=1

JOBS="${MAKEJOBS:-}"
if [ -z "$JOBS" ]; then
  NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  [ "$NCPU" -ge 1 ] 2>/dev/null || NCPU=1
  JOBS="-j$NCPU"
fi

log "source: $SRC_DIR"
log "XNU: $XNU_VERSION ($XNU_COMMIT)"
log "configuration: RELEASE I386"
log "SDK: $SDKROOT"
log "MAKEJOBS: $JOBS"

cd "$SRC_DIR"
make \
  ARCH_CONFIGS=I386 \
  KERNEL_CONFIGS=RELEASE \
  SDKROOT="$SDKROOT" \
  OBJROOT="$OBJROOT" \
  SYMROOT="$SYMROOT" \
  DSTROOT="$DSTROOT" \
  RELPATH="$RELPATH_TOOL" \
  DECOMMENT="$DECOMMENT_TOOL" \
  SEG_HACK="$SETSEGNAME_TOOL" \
  KEXT_CREATE_SYMBOL_SET="$KEXTSYMBOLTOOL_TOOL" \
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
git -C "$ROOT_DIR/../.." diff -- kernel/Atom-Kernel-N570/src/xnu/osfmk/i386/cpuid.h kernel/Atom-Kernel-N570/src/xnu/osfmk/i386/cpuid.c kernel/Atom-Kernel-N570/src/xnu/osfmk/i386/i386_init.c > "$ARTIFACT_DIR/source.patch" 2>/dev/null || true
shasum -a 256 "$ARTIFACT_DIR/mach_kernel" > "$ARTIFACT_DIR/mach_kernel.sha256"

log "N570 RELEASE build complete: $ARTIFACT_DIR/mach_kernel"
cat "$ARTIFACT_DIR/mach_kernel.sha256"
log "next: bash '$SCRIPT_DIR/test_n570_release.sh' '$ARTIFACT_DIR/mach_kernel'"
