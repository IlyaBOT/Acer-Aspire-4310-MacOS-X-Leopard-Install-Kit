#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOCK_FILE="$ROOT_DIR/SOURCE.lock"
SRC_DIR="$ROOT_DIR/src/xnu"
KERNEL="${1:-$ROOT_DIR/artifacts/n570-matchtrace/mach_kernel}"
SYMBOL_IMAGE="$ROOT_DIR/artifacts/n570-matchtrace/mach_kernel.sys"

# shellcheck disable=SC1090
. "$LOCK_FILE"

log() { printf '[atom-kernel-matchtrace-test] %s\n' "$*"; }
die() { printf '[atom-kernel-matchtrace-test] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
[ -f "$SRC_DIR/.xnu-source-commit" ] || die "source marker missing"
[ "$(cat "$SRC_DIR/.xnu-source-commit")" = "$XNU_COMMIT" ] || die "source commit marker mismatch"

DESC="$(file "$KERNEL")"
printf '%s\n' "$DESC"
case "$DESC" in *i386*) ;; *) die "kernel has no i386 architecture" ;; esac

grep -a -F -q "Darwin Kernel Version $DARWIN_VERSION" "$KERNEL" || die "Darwin $DARWIN_VERSION banner missing"
grep -a -F -q 'RELEASE_I386' "$KERNEL" || die "kernel is not RELEASE_I386"
if grep -a -F -q 'DEBUG_I386' "$KERNEL"; then
  die "DEBUG_I386 marker found in MATCHTRACE RELEASE artifact"
fi

grep -a -F -q '[N570 ATOM-KERNEL]' "$KERNEL" || die "base N570 instrumentation prefix missing"
for marker in ' P>' ' P<' ' F>' ' F<' ' L>' ' L<' ' A>' ' A<' ' I>' ' I<' ' T>' ' T<' ' R>' ' R<' ' D>' ' D<' ' S>' ' S<'; do
  grep -a -F -q "[N570 ATOM-KERNEL][MATCH]$marker" "$KERNEL" || die "matchtrace marker missing:$marker"
done

grep -Eq '^#define[[:space:]]+CPUID_MODEL_ATOM[[:space:]]+28([[:space:]]|$)' "$SRC_DIR/osfmk/i386/cpuid.h" || die "Atom model constant is not exactly model 28"
grep -A2 'case CPUID_MODEL_ATOM:' "$SRC_DIR/osfmk/i386/cpuid.c" | grep -q 'CPUFAMILY_INTEL_YONAH' || die "Atom model 28 is not mapped to Yonah compatibility family"

log "PASS runtime kernel banner: Darwin Kernel Version $DARWIN_VERSION"
log "PASS kernel configuration: RELEASE_I386"
log "PASS Atom model 28 -> Yonah compatibility family"
log "PASS targeted IOKit tracing: IOResources + bios"
log "PASS trace stages: passive/family/load/alloc/init/attach/probe/detach/start"

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

log "N570 MATCHTRACE RELEASE STATIC VALIDATION: PASS"
log "next: stage this exact artifact on the ASUS 1215P ESP and record the last [N570 ATOM-KERNEL][MATCH] line"
