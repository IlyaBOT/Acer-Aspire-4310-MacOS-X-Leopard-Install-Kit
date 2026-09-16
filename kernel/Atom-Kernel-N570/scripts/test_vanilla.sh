#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOCK_FILE="$ROOT_DIR/SOURCE.lock"
SRC_DIR="$ROOT_DIR/src/xnu"
KERNEL="${1:-$ROOT_DIR/artifacts/vanilla/mach_kernel}"
RETAIL="${2:-}"

# shellcheck disable=SC1090
. "$LOCK_FILE"

log() { printf '[atom-kernel-test] %s\n' "$*"; }
die() { printf '[atom-kernel-test] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
[ -f "$SRC_DIR/.xnu-source-commit" ] || die "source marker missing"
[ "$(cat "$SRC_DIR/.xnu-source-commit")" = "$XNU_COMMIT" ] || die "source commit marker mismatch"

DESC="$(file "$KERNEL")"
printf '%s\n' "$DESC"
case "$DESC" in
  *i386*) ;;
  *) die "kernel has no i386 architecture" ;;
esac

# Use fixed-string matching here. The previous BRE pattern accidentally used
# double backslashes inside single quotes and therefore looked for literal
# backslashes instead of the dots in xnu-1504.3.12.
if grep -a -F -q 'xnu-1504.3.12' "$KERNEL"; then
  log "PASS xnu-1504.3.12 version string"
else
  die "xnu-1504.3.12 version string not found"
fi

if grep -a -F -q 'Darwin Kernel Version 10.3.0' "$KERNEL"; then
  log "PASS Darwin 10.3.0 version string"
else
  log "NOTE exact Darwin banner not found in raw binary; xnu version string matched"
fi

if grep -a -F -q '[N570 ATOM-KERNEL]' "$KERNEL"; then
  die "N570 debug prefix found in vanilla artifact"
else
  log "PASS no N570 patch/debug marker in vanilla artifact"
fi

if grep -R -F -q '[N570 ATOM-KERNEL]' "$SRC_DIR" 2>/dev/null; then
  die "N570 debug prefix found in vanilla source tree"
else
  log "PASS source tree is still vanilla with respect to N570 diagnostics"
fi

# Confirm the source still contains the known vanilla Atom blocker.
CPUID_C="$SRC_DIR/osfmk/i386/cpuid.c"
[ -f "$CPUID_C" ] || die "missing osfmk/i386/cpuid.c"
grep -q 'panic("Unsupported CPU")' "$CPUID_C" || die "vanilla Unsupported CPU guard not found"
if grep -Eq 'case[[:space:]]+(28|0x1[Cc])' "$CPUID_C"; then
  die "model 28 already appears as an accepted cpuid_set_cpufamily case; source is not expected vanilla baseline"
fi
log "PASS vanilla CPUID blocker is present (Atom model 28 not accepted)"

if have otool; then
  log "Mach-O header"
  otool -hv "$KERNEL" || die "otool could not parse kernel"
fi

if have nm; then
  SYMBOL_IMAGE="$ROOT_DIR/artifacts/vanilla/mach_kernel.sys"
  if [ -f "$SYMBOL_IMAGE" ]; then
    for sym in _vstart _i386_init _cpuid_set_info _machine_startup; do
      if nm "$SYMBOL_IMAGE" 2>/dev/null | grep -q " $sym$"; then
        log "PASS symbol $sym"
      else
        log "WARN symbol not found in mach_kernel.sys: $sym"
      fi
    done
  else
    log "NOTE mach_kernel.sys not present; symbol checks skipped"
  fi
fi

if have shasum; then
  log "SHA-256"
  shasum -a 256 "$KERNEL"
elif have openssl; then
  openssl dgst -sha256 "$KERNEL"
fi

if [ -n "$RETAIL" ]; then
  [ -f "$RETAIL" ] || die "retail kernel not found: $RETAIL"
  log "retail comparison is informational only; independently built kernels are not expected to be byte-identical"
  printf 'self-built: '
  shasum -a 256 "$KERNEL" | awk '{print $1}'
  printf 'retail:     '
  shasum -a 256 "$RETAIL" | awk '{print $1}'
  if cmp -s "$KERNEL" "$RETAIL"; then
    log "NOTE self-built kernel is byte-identical to retail"
  else
    log "PASS artifacts differ bytewise; this is acceptable if architecture/version/boot tests pass"
  fi
fi

log "STATIC VANILLA VALIDATION: PASS"
log "next control test: boot this kernel on a supported CPU environment before applying any N570 patch"
