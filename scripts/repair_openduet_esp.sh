#!/usr/bin/env bash
set -Eeuo pipefail

DISK=""
BUILD_ROOT=""
ESP_PART=""
REFORMAT_ESP=0
TEMP_DIR=""
ESP_MOUNT=""

usage() {
  cat <<'USAGE'
Repair/reinstall the OpenCore/OpenDuet ESP on an existing installer USB.
The HFS/HFS+ installer partition is not modified.

Example:
  sudo bash scripts/repair_openduet_esp.sh \
    --disk /dev/sdX \
    --build-root output/targets/emachines-d640-n930/snowleopard/opencore \
    --reformat-esp

Options:
  --disk /dev/sdX       whole removable/USB disk
  --build-root PATH     prepared OpenCore target build root
  --esp-part /dev/sdX1  override EFI partition discovery
  --reformat-esp        recreate the EFI partition as FAT32 before reinstalling
USAGE
}

log() { printf '[openduet-repair] %s\n' "$*"; }
die() { printf '[openduet-repair] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  set +e
  [[ -n "$ESP_MOUNT" ]] && mountpoint -q "$ESP_MOUNT" && umount "$ESP_MOUNT"
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }
while (($#)); do
  case "$1" in
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --build-root) need_value "$@"; shift; BUILD_ROOT="$1" ;;
    --esp-part) need_value "$@"; shift; ESP_PART="$1" ;;
    --reformat-esp) REFORMAT_ESP=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ "$(uname -s)" == Linux ]] || die "Linux only"
[[ $EUID -eq 0 ]] || die "Run as root"
[[ -n "$DISK" && -b "$DISK" ]] || die "--disk must be a block device"
[[ "$(lsblk -dnro TYPE "$DISK")" == disk ]] || die "--disk must name a whole disk"
[[ -n "$BUILD_ROOT" ]] || die "--build-root is required"
BUILD_ROOT="$(readlink -f "$BUILD_ROOT")"

for cmd in lsblk findmnt blkid mkfs.vfat mount umount dd sync stat; do
  have "$cmd" || die "Missing required command: $cmd"
done

root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
root_parent=""
if [[ -n "$root_source" && -b "$root_source" ]]; then
  root_parent="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
  [[ -n "$root_parent" ]] && root_parent="/dev/$root_parent"
fi
[[ "$DISK" != "$root_source" && "$DISK" != "$root_parent" ]] || die "Refusing Linux root disk: $DISK"

rm_flag="$(lsblk -dnro RM "$DISK" | tr -d ' ')"
transport="$(lsblk -dnro TRAN "$DISK" | tr -d ' ')"
[[ "$rm_flag" == 1 || "$transport" == usb ]] || die "$DISK is not clearly removable/USB"

if [[ -z "$ESP_PART" ]]; then
  ESP_PART="$(lsblk -lnpo NAME,PARTN "$DISK" | awk '$2 == 1 {print $1; exit}')"
fi
[[ -n "$ESP_PART" && -b "$ESP_PART" ]] || die "Could not identify EFI partition"

for file in \
  "$BUILD_ROOT/ESP/EFI/OC/config.plist" \
  "$BUILD_ROOT/ESP/EFI/BOOT/BOOTIA32.efi" \
  "$BUILD_ROOT/OpenDuet/boot0" \
  "$BUILD_ROOT/OpenDuet/boot1f32" \
  "$BUILD_ROOT/OpenDuet/bootIA32"; do
  [[ -f "$file" ]] || die "Missing build artifact: $file"
done

unmount_disk() {
  local target
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    umount "$target" 2>/dev/null || true
  done < <(lsblk -lnpo MOUNTPOINTS "$DISK" | awk 'NF')
}

settle() {
  have partprobe && partprobe "$DISK" >/dev/null 2>&1 || true
  have udevadm && udevadm settle || true
}

wait_for_block() {
  local path="$1" i
  for ((i=0; i<100; i++)); do
    [[ -b "$path" ]] && return 0
    have udevadm && udevadm settle >/dev/null 2>&1 || true
    sleep 0.1
  done
  return 1
}

TEMP_DIR="$(mktemp -d /tmp/openduet-repair.XXXXXX)"
ESP_MOUNT="$TEMP_DIR/esp"
mkdir -p "$ESP_MOUNT"

unmount_disk
settle
wait_for_block "$ESP_PART" || die "$ESP_PART did not reappear after settling"

if (( REFORMAT_ESP == 1 )); then
  printf 'WARNING: this will reformat ONLY %s; the installer partition is not touched.\n' "$ESP_PART"
  printf 'Type exactly: REFORMAT ESP %s ON %s\n> ' "$ESP_PART" "$DISK"
  IFS= read -r answer
  [[ "$answer" == "REFORMAT ESP $ESP_PART ON $DISK" ]] || die "Confirmation mismatch"
  log "Formatting $ESP_PART as FAT32"
  mkfs.vfat -F 32 -n OPENCORE "$ESP_PART"
  sync
  settle
  wait_for_block "$ESP_PART" || die "$ESP_PART disappeared after mkfs.vfat"
fi

fstype="$(blkid -s TYPE -o value "$ESP_PART" 2>/dev/null || true)"
[[ "$fstype" == vfat || "$fstype" == msdos || "$fstype" == fat ]] \
  || die "$ESP_PART is not a readable FAT filesystem ($fstype); rerun with --reformat-esp"

log "Copying OpenCore EFI tree"
mount -t vfat -o rw,noatime "$ESP_PART" "$ESP_MOUNT"
rm -rf -- "$ESP_MOUNT/EFI"
mkdir -p "$ESP_MOUNT/EFI"
cp -R --no-preserve=ownership,mode,timestamps "$BUILD_ROOT/ESP/EFI"/. "$ESP_MOUNT/EFI"/
cp --no-preserve=ownership,mode,timestamps "$BUILD_ROOT/OpenDuet/bootIA32" "$ESP_MOUNT/boot"
sync
umount "$ESP_MOUNT"

# OpenCorePkg LegacyBoot sequence, made robust for USB devices whose partition
# node can disappear briefly after the MBR boot0 write. Read and validate the
# FAT PBR first; never continue if the original BPB cannot be captured.
origbs="$TEMP_DIR/origbs"
newbs="$TEMP_DIR/newbs"
wait_for_block "$ESP_PART" || die "$ESP_PART unavailable before PBR backup"
dd if="$ESP_PART" of="$origbs" bs=512 count=1 status=none
a_size="$(stat -c '%s' "$origbs")"
[[ "$a_size" == 512 ]] || die "Could not capture a complete 512-byte FAT PBR"

cp "$BUILD_ROOT/OpenDuet/boot1f32" "$newbs"
dd if="$origbs" of="$newbs" skip=3 seek=3 bs=1 count=87 conv=notrunc status=none
dd if=/dev/urandom of="$newbs" skip=496 seek=496 bs=1 count=14 conv=notrunc status=none

log "Writing OpenCorePkg boot0 to $DISK"
dd if="$BUILD_ROOT/OpenDuet/boot0" of="$DISK" bs=1 count=446 conv=notrunc,fsync status=none
settle
wait_for_block "$ESP_PART" || die "$ESP_PART did not reappear after boot0 write"

log "Writing patched boot1f32 PBR to $ESP_PART"
dd if="$newbs" of="$ESP_PART" bs=512 count=1 conv=notrunc,fsync status=none
sync
settle
wait_for_block "$ESP_PART" || die "$ESP_PART did not reappear after boot1f32 write"

fstype="$(blkid -s TYPE -o value "$ESP_PART" 2>/dev/null || true)"
[[ "$fstype" == vfat || "$fstype" == msdos || "$fstype" == fat ]] \
  || die "FAT filesystem is no longer readable after boot1f32 write ($fstype)"

mount -t vfat -o ro "$ESP_PART" "$ESP_MOUNT"
[[ -f "$ESP_MOUNT/EFI/OC/config.plist" ]] || die "Missing EFI/OC/config.plist after repair"
[[ -f "$ESP_MOUNT/EFI/BOOT/BOOTIA32.efi" ]] || die "Missing EFI/BOOT/BOOTIA32.efi after repair"
[[ -f "$ESP_MOUNT/boot" ]] || die "Missing OpenDuet /boot after repair"
umount "$ESP_MOUNT"

log "PASS repaired FAT32 ESP and OpenDuet boot chain"
