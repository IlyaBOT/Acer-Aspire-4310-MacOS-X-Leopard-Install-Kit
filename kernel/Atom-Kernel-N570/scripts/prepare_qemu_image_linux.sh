#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SOURCE_DISK=""
OUTPUT_IMAGE=""
KERNEL="${KERNEL:-$ROOT_DIR/artifacts/vanilla/mach_kernel}"
LOOP=""
MOUNT_DIR=""

log() { printf '[atom-kernel-qemu-prep] %s\n' "$*"; }
die() { printf '[atom-kernel-qemu-prep] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  if [ -n "$MOUNT_DIR" ] && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    umount "$MOUNT_DIR" || true
  fi
  [ -n "$MOUNT_DIR" ] && rmdir "$MOUNT_DIR" 2>/dev/null || true
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --source-disk) shift; SOURCE_DISK="${1:-}" ;;
    --output) shift; OUTPUT_IMAGE="${1:-}" ;;
    --kernel) shift; KERNEL="${1:-}" ;;
    -h|--help)
      echo "usage: sudo $0 --source-disk /dev/sdX --output /path/test.raw [--kernel /path/mach_kernel]"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ "$(uname -s)" = Linux ] || die "this helper is Linux-only"
[ "$(id -u)" -eq 0 ] || die "run as root/sudo"
[ -n "$SOURCE_DISK" ] || die "--source-disk is required"
[ -n "$OUTPUT_IMAGE" ] || die "--output is required"
[ -b "$SOURCE_DISK" ] || die "source is not a block device: $SOURCE_DISK"
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"

for c in lsblk dd losetup mount umount mountpoint sync file grep; do have "$c" || die "missing command: $c"; done

TYPE="$(lsblk -dn -o TYPE "$SOURCE_DISK" 2>/dev/null || true)"
[ "$TYPE" = disk ] || die "source must be a whole disk, not a partition"

ROOT_PARENT="$(findmnt -n -o SOURCE / 2>/dev/null | sed -E 's/p?[0-9]+$//' || true)"
if [ -n "$ROOT_PARENT" ] && [ "$SOURCE_DISK" = "$ROOT_PARENT" ]; then
  die "refusing to image the current root disk"
fi

case "$(file "$KERNEL")" in *i386*) ;; *) die "kernel has no i386 architecture" ;; esac
grep -a -q 'xnu-1504\.3\.12' "$KERNEL" || die "kernel is not xnu-1504.3.12"

[ ! -e "$OUTPUT_IMAGE" ] || die "output already exists: $OUTPUT_IMAGE"
mkdir -p "$(dirname "$OUTPUT_IMAGE")"

log "cloning $SOURCE_DISK -> $OUTPUT_IMAGE"
if dd --help 2>&1 | grep -q 'status='; then
  dd if="$SOURCE_DISK" of="$OUTPUT_IMAGE" bs=4M conv=sparse status=progress
else
  dd if="$SOURCE_DISK" of="$OUTPUT_IMAGE" bs=4M conv=sparse
fi
sync

LOOP="$(losetup --find --show --partscan "$OUTPUT_IMAGE")"
log "loop device: $LOOP"

ESP_PART="${LOOP}p1"
for _ in 1 2 3 4 5; do
  [ -b "$ESP_PART" ] && break
  sleep 1
done
[ -b "$ESP_PART" ] || die "first partition did not appear: $ESP_PART"

FSTYPE="$(lsblk -dn -o FSTYPE "$ESP_PART" 2>/dev/null || true)"
case "$FSTYPE" in vfat|fat|fat32) ;; *) die "partition 1 is not FAT: $ESP_PART ($FSTYPE)" ;; esac

MOUNT_DIR="$(mktemp -d /tmp/atom-qemu-esp.XXXXXX)"
mount "$ESP_PART" "$MOUNT_DIR"
bash "$SCRIPT_DIR/stage_kernel.sh" "$KERNEL" "$MOUNT_DIR"
sync
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
MOUNT_DIR=""
losetup -d "$LOOP"
LOOP=""

log "QEMU test image ready: $OUTPUT_IMAGE"
log "boot with: bash '$SCRIPT_DIR/qemu_boot.sh' '$OUTPUT_IMAGE'"
