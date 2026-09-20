#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SOURCE_DISK=""
OUTPUT_IMAGE=""
PROFILE="vanilla"
KERNEL=""
LOOP=""
MOUNT_DIR=""

log() { printf "[qemu-esp-prep] %s\n" "$*"; }
die() { printf "[qemu-esp-prep] ERROR: %s\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  if [ -n "$MOUNT_DIR" ] && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then umount "$MOUNT_DIR" || true; fi
  [ -n "$MOUNT_DIR" ] && rmdir "$MOUNT_DIR" 2>/dev/null || true
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --source-disk) shift; SOURCE_DISK="${1:-}" ;;
    --output) shift; OUTPUT_IMAGE="${1:-}" ;;
    --profile) shift; PROFILE="${1:-}" ;;
    --kernel) shift; KERNEL="${1:-}" ;;
    -h|--help) echo "usage: sudo $0 --source-disk /dev/sdX [--profile vanilla|atom] [--kernel /path/mach_kernel] [--output /path/image.raw]"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ "$(uname -s)" = Linux ] || die "this helper is Linux-only"
[ "$(id -u)" -eq 0 ] || die "run as root/sudo"
[ -n "$SOURCE_DISK" ] || die "--source-disk is required"
[ -b "$SOURCE_DISK" ] || die "source is not a block device: $SOURCE_DISK"
case "$PROFILE" in vanilla|atom) ;; *) die "--profile must be vanilla or atom" ;; esac

if [ -z "$KERNEL" ]; then
  if [ "$PROFILE" = atom ]; then KERNEL="$ROOT_DIR/artifacts/n570-debug/mach_kernel"; else KERNEL="$ROOT_DIR/artifacts/vanilla/mach_kernel"; fi
fi
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"

if [ -z "$OUTPUT_IMAGE" ]; then OUTPUT_IMAGE="$ROOT_DIR/artifacts/qemu/asus1215p-$PROFILE-esp.raw"; fi
[ ! -e "$OUTPUT_IMAGE" ] || die "output already exists: $OUTPUT_IMAGE"
mkdir -p "$(dirname "$OUTPUT_IMAGE")"

for c in lsblk blockdev dd truncate losetup mount umount mountpoint awk sync; do have "$c" || die "missing command: $c"; done
[ "$(lsblk -dn -o TYPE "$SOURCE_DISK" 2>/dev/null || true)" = disk ] || die "source must be a whole disk"

ESP_PART="$(lsblk -nrpo NAME,PARTN "$SOURCE_DISK" | awk '$2 == "1" {print $1; exit}')"
[ -n "$ESP_PART" ] && [ -b "$ESP_PART" ] || die "could not locate partition 1 on $SOURCE_DISK"

SECTOR_SIZE="$(blockdev --getss "$SOURCE_DISK")"
START_SECTOR="$(blockdev --getstartsect "$ESP_PART")"
ESP_SIZE="$(blockdev --getsize64 "$ESP_PART")"
DISK_SIZE="$(blockdev --getsize64 "$SOURCE_DISK")"
HEAD_BYTES=$((START_SECTOR * SECTOR_SIZE + ESP_SIZE))
HEAD_SECTORS=$((HEAD_BYTES / SECTOR_SIZE))
TAIL_BYTES=1048576
TAIL_SECTORS=$((TAIL_BYTES / SECTOR_SIZE))
TOTAL_SECTORS=$((DISK_SIZE / SECTOR_SIZE))
TAIL_START=$((TOTAL_SECTORS - TAIL_SECTORS))

log "creating sparse image with original disk geometry"
truncate -s "$DISK_SIZE" "$OUTPUT_IMAGE"
log "copying MBR/GPT + ESP only"
dd if="$SOURCE_DISK" of="$OUTPUT_IMAGE" bs="$SECTOR_SIZE" count="$HEAD_SECTORS" conv=notrunc,sparse status=progress
log "copying backup GPT tail"
dd if="$SOURCE_DISK" of="$OUTPUT_IMAGE" bs="$SECTOR_SIZE" skip="$TAIL_START" seek="$TAIL_START" count="$TAIL_SECTORS" conv=notrunc,sparse status=none
sync

LOOP="$(losetup --find --show --partscan "$OUTPUT_IMAGE")"
ESP_LOOP="${LOOP}p1"
for _ in 1 2 3 4 5; do [ -b "$ESP_LOOP" ] && break; sleep 1; done
[ -b "$ESP_LOOP" ] || die "partition 1 did not appear in sparse image: $ESP_LOOP"

MOUNT_DIR="$(mktemp -d /tmp/atom-qemu-esp.XXXXXX)"
mount "$ESP_LOOP" "$MOUNT_DIR"
bash "$SCRIPT_DIR/stage_kernel.sh" "$KERNEL" "$MOUNT_DIR"
sync
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
MOUNT_DIR=""
losetup -d "$LOOP"
LOOP=""

log "EFI-only sparse QEMU image ready: $OUTPUT_IMAGE"
log "DVD/HFS payload was not copied; attach the Snow Leopard ISO separately when launching QEMU"
