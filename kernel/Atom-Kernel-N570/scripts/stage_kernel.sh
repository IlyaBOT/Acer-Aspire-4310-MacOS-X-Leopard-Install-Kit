#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
KERNEL="${1:-$ROOT_DIR/artifacts/vanilla/mach_kernel}"
ESP="${2:-}"

log() { printf '[atom-kernel-stage] %s\n' "$*"; }
die() { printf '[atom-kernel-stage] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
[ -n "$ESP" ] || die "usage: $0 /path/to/mach_kernel /path/to/mounted/ESP"
[ -d "$ESP" ] || die "ESP mount point not found: $ESP"
[ -d "$ESP/EFI/OC" ] || die "not an expected OpenCore ESP: missing EFI/OC"
mkdir -p "$ESP/Kernels"
TARGET="$ESP/Kernels/mach_kernel"

DESC="$(file "$KERNEL")"
case "$DESC" in *i386*) ;; *) die "kernel has no i386 architecture: $DESC" ;; esac
grep -a -F -q 'Darwin Kernel Version 10.3.0' "$KERNEL" || die "kernel is not Darwin 10.3.0"

if [ -f "$TARGET" ]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$TARGET.backup-$stamp"
  cp -p "$TARGET" "$backup"
  log "backup: $backup"
fi

cp -p "$KERNEL" "$TARGET"
sync

if command -v shasum >/dev/null 2>&1; then
  src_sha="$(shasum -a 256 "$KERNEL" | awk '{print $1}')"
  dst_sha="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
else
  src_sha="$(openssl dgst -sha256 "$KERNEL" | awk '{print $NF}')"
  dst_sha="$(openssl dgst -sha256 "$TARGET" | awk '{print $NF}')"
fi
[ "$src_sha" = "$dst_sha" ] || die "copy verification failed"

log "staged Snow Leopard custom kernel: $TARGET"
log "SHA-256: $dst_sha"
