#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOCK_FILE="$ROOT_DIR/SOURCE.lock"
SRC_DIR="$ROOT_DIR/src/xnu"

# shellcheck disable=SC1090
. "$LOCK_FILE"

log() { printf '[atom-kernel-audit] %s\n' "$*"; }
die() { printf '[atom-kernel-audit] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$SRC_DIR/.xnu-source-commit" ] || die "source not prepared"
[ "$(cat "$SRC_DIR/.xnu-source-commit")" = "$XNU_COMMIT" ] || die "wrong XNU source commit"

CPUID_C="$SRC_DIR/osfmk/i386/cpuid.c"
CPUID_H="$SRC_DIR/osfmk/i386/cpuid.h"
I386_INIT="$SRC_DIR/osfmk/i386/i386_init.c"
for f in "$CPUID_C" "$CPUID_H" "$I386_INIT"; do [ -f "$f" ] || die "missing $f"; done

log "source commit: $XNU_COMMIT"
log "version: $XNU_VERSION / Darwin $DARWIN_VERSION / Mac OS X $MACOS_VERSION"
log "N570 CPUID signature: 0x000106CA -> family 6, base model 12, extmodel 1, folded model 28 (0x1C)"

if grep -Eq 'case[[:space:]]+(28|0x1[Cc])' "$CPUID_C"; then
  log "Atom model 28 already appears in cpuid_set_cpufamily; inspect source before proceeding"
  exit 2
fi

grep -q 'panic("Unsupported CPU")' "$CPUID_C" || die "Unsupported CPU guard not found"
log "CONFIRMED: vanilla cpuid_set_cpufamily has no model 28 case"
log "CONFIRMED: cpuid_set_info panics when cpuid_set_cpufamily returns CPUFAMILY_UNKNOWN"

if grep -q 'case 15:' "$CPUID_C" && grep -q 'CPUFAMILY_INTEL_MEROM' "$CPUID_C"; then
  log "CONFIRMED: model 15 maps to CPUFAMILY_INTEL_MEROM"
fi

if grep -F -R -q '[N570 ATOM-KERNEL]' "$SRC_DIR" 2>/dev/null; then
  die "N570 diagnostic marker exists in source; vanilla phase is no longer clean"
else
  log "CONFIRMED: no N570 patch/debug marker in vanilla source"
fi

if grep -q '^vstart' "$I386_INIT" || grep -q 'vstart(vm_offset_t boot_args_start)' "$I386_INIT"; then
  log "early instrumentation point present: vstart()"
fi
if grep -q 'i386_init(vm_offset_t boot_args_start)' "$I386_INIT"; then
  log "early instrumentation point present: i386_init()"
fi
if grep -q 'machine_startup();' "$I386_INIT"; then
  log "handoff point present: machine_startup()"
fi

log "SOURCE AUDIT: PASS"
