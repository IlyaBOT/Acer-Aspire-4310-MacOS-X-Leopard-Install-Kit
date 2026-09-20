#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOCK_FILE="$ROOT_DIR/SOURCE.lock"
SRC_DIR="$ROOT_DIR/src/xnu"
KERNEL="${1:-$ROOT_DIR/artifacts/n570-debug/mach_kernel}"
SYMBOL_IMAGE="$ROOT_DIR/artifacts/n570-debug/mach_kernel.sys"

# shellcheck disable=SC1090
. "$LOCK_FILE"

log() { printf '[atom-kernel-debug-test] %s\n' "$*"; }
die() { printf '[atom-kernel-debug-test] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
[ -f "$SRC_DIR/.xnu-source-commit" ] || die "source marker missing"
[ "$(cat "$SRC_DIR/.xnu-source-commit")" = "$XNU_COMMIT" ] || die "source commit marker mismatch"

MASTER_VERSION="$(sed -n '1p' "$SRC_DIR/config/MasterVersion" | tr -d '\r\n')"
[ "$MASTER_VERSION" = "$DARWIN_VERSION" ] || die "MasterVersion mismatch: expected $DARWIN_VERSION, got $MASTER_VERSION"

DESC="$(file "$KERNEL")"
printf '%s\n' "$DESC"
case "$DESC" in *i386*) ;; *) die "kernel has no i386 architecture" ;; esac

EXPECTED_BANNER="Darwin Kernel Version $DARWIN_VERSION"
grep -a -F -q "$EXPECTED_BANNER" "$KERNEL" || die "runtime kernel banner not found: $EXPECTED_BANNER"
log "PASS runtime kernel banner: $EXPECTED_BANNER"
grep -a -F -q 'DEBUG_I386' "$KERNEL" || die "kernel banner does not identify a DEBUG_I386 build"
log "PASS kernel configuration: DEBUG_I386"

if grep -a -F -q "$XNU_VERSION" "$KERNEL"; then
  log "INFO Apple OSS package label is also embedded: $XNU_VERSION"
else
  log "INFO $XNU_VERSION is not embedded in this local build; provenance is verified from the pinned source commit"
fi

grep -a -F -q '[N570 ATOM-KERNEL]' "$KERNEL" || die "N570 debug prefix not found in built kernel"
grep -Eq '^#define[[:space:]]+CPUID_MODEL_ATOM[[:space:]]+28([[:space:]]|$)' "$SRC_DIR/osfmk/i386/cpuid.h" || die "Atom model constant is not exactly model 28"
grep -q 'case CPUID_MODEL_ATOM:' "$SRC_DIR/osfmk/i386/cpuid.c" || die "Atom acceptance case missing"
grep -A2 'case CPUID_MODEL_ATOM:' "$SRC_DIR/osfmk/i386/cpuid.c" | grep -q 'CPUFAMILY_INTEL_YONAH' || die "Atom is not mapped to the historical Yonah compatibility family"
if grep -Eq 'cpuid_model[[:space:]]*=[[:space:]]*(15|CPUID_MODEL_MEROM|14|CPUID_MODEL_YONAH)' "$SRC_DIR/osfmk/i386/cpuid.c"; then
  die "source rewrites cpuid_model to another CPU model"
fi

log "PASS source provenance: $XNU_VERSION / commit $XNU_COMMIT"
log "PASS Atom model 28 is represented explicitly in source"
log "PASS Atom model 28 is accepted via Yonah compatibility family without CPUID model spoofing"
log "PASS debug prefix is embedded in kernel"

if have otool; then
  otool -hv "$KERNEL" || die "otool could not parse kernel"
fi

if have nm && [ -f "$SYMBOL_IMAGE" ]; then
  for sym in _vstart _i386_init _cpuid_set_info _machine_startup; do
    if nm "$SYMBOL_IMAGE" 2>/dev/null | grep -q " $sym$"; then
      log "PASS symbol $sym"
    else
      log "WARN symbol not found in mach_kernel.sys: $sym"
    fi
  done
fi

if have shasum; then
  shasum -a 256 "$KERNEL"
elif have openssl; then
  openssl dgst -sha256 "$KERNEL"
fi

log "N570 DEBUG STATIC VALIDATION: PASS"
log "QEMU Atom-profile test: QEMU_CPU='n270,+lm,+nx' QEMU_SMP=4 bash scripts/qemu_boot.sh <image.raw>"
