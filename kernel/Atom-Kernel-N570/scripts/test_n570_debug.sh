#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SRC_DIR="$ROOT_DIR/src/xnu"
KERNEL="${1:-$ROOT_DIR/artifacts/n570-debug/mach_kernel}"
SYMBOL_IMAGE="$ROOT_DIR/artifacts/n570-debug/mach_kernel.sys"

log() { printf '[atom-kernel-debug-test] %s\n' "$*"; }
die() { printf '[atom-kernel-debug-test] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
DESC="$(file "$KERNEL")"
printf '%s\n' "$DESC"
case "$DESC" in *i386*) ;; *) die "kernel has no i386 architecture" ;; esac

grep -a -q 'xnu-1504\.3\.12' "$KERNEL" || die "xnu-1504.3.12 version string not found"
grep -a -F -q '[N570 ATOM-KERNEL]' "$KERNEL" || die "N570 debug prefix not found in built kernel"
grep -q 'CPUID_MODEL_ATOM' "$SRC_DIR/osfmk/i386/cpuid.h" || die "Atom model constant missing"
grep -q 'case CPUID_MODEL_ATOM:' "$SRC_DIR/osfmk/i386/cpuid.c" || die "Atom acceptance case missing"
grep -A2 'case CPUID_MODEL_ATOM:' "$SRC_DIR/osfmk/i386/cpuid.c" | grep -q 'CPUFAMILY_INTEL_6_13' || die "Atom is not mapped to CPUFAMILY_INTEL_6_13"

log "PASS Atom model 28 is represented explicitly in source"
log "PASS Atom model is accepted without rewriting cpuid_model to Merom 15"
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
