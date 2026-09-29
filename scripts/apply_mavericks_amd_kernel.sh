#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEFAULT_KERNEL="$ROOT_DIR/cache/a8-7600-mavericks/amd/mach_kernel"
VOLUME=""
KERNEL="$DEFAULT_KERNEL"
REBUILD_CACHE=0

log() { printf '[mavericks-amd-kernel] %s\n' "$*"; }
warn() { printf '[mavericks-amd-kernel] WARNING: %s\n' "$*" >&2; }
die() { printf '[mavericks-amd-kernel] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Install the pinned Mavericks DEBUG mach_kernel into a writable Mavericks root.

Usage:
  sudo ./scripts/apply_mavericks_amd_kernel.sh --volume /mnt/Mavericks
  sudo ./scripts/apply_mavericks_amd_kernel.sh --volume "/Volumes/OS X Base System"
  sudo ./scripts/apply_mavericks_amd_kernel.sh --volume /Volumes/Mavericks --rebuild-cache

The existing /mach_kernel is backed up before replacement. The normal A8 profile
uses OpenCore KernelCache=Cacheless so cache rebuilding is not required for the
first bring-up. --rebuild-cache is available only when a compatible kextcache
binary can operate on the target volume.
EOF
}

need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }
while (($#)); do
  case "$1" in
    --volume) need_value "$@"; shift; VOLUME="$1" ;;
    --kernel) need_value "$@"; shift; KERNEL="$1" ;;
    --rebuild-cache) REBUILD_CACHE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$VOLUME" ]] || { usage; exit 2; }
[[ -d "$VOLUME" ]] || die "Volume/root directory not found: $VOLUME"
[[ -f "$KERNEL" ]] || die "AMD DEBUG kernel not found: $KERNEL"
[[ -w "$VOLUME" ]] || die "Target root is not writable: $VOLUME"

python3 - "$KERNEL" <<'PY'
from pathlib import Path
import sys
data=Path(sys.argv[1]).read_bytes()
if not data.startswith((b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")):
    raise SystemExit("kernel is not a recognised Mach-O/FAT file")
if b"Darwin Kernel Version 13." not in data and b"xnu-2422" not in data:
    raise SystemExit("kernel does not identify as a Mavericks/Darwin 13 build")
PY

TARGET="$VOLUME/mach_kernel"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
if [[ -e "$TARGET" ]]; then
  BACKUP="$VOLUME/mach_kernel.pre-amd-$STAMP"
  cp -f -- "$TARGET" "$BACKUP"
  log "Backed up existing kernel: $BACKUP"
fi

cp -f -- "$KERNEL" "$TARGET"
chmod 0644 "$TARGET"
if [[ $EUID -eq 0 ]]; then
  chown 0:0 "$TARGET" 2>/dev/null || true
fi
sync

if command -v cmp >/dev/null 2>&1; then
  cmp -s "$KERNEL" "$TARGET" || die "Kernel verification failed after copy"
fi
log "Installed AMD Mavericks DEBUG kernel: $TARGET"

if (( REBUILD_CACHE == 1 )); then
  if command -v kextcache >/dev/null 2>&1; then
    log "Rebuilding target prelinked/kernel caches with kextcache"
    kextcache -u "$VOLUME" || die "kextcache failed for $VOLUME"
  else
    die "--rebuild-cache requested but kextcache is not available on this host"
  fi
else
  warn "Kernel cache was not rebuilt. The generated A8 OpenCore profile uses KernelCache=Cacheless for first boot."
fi
