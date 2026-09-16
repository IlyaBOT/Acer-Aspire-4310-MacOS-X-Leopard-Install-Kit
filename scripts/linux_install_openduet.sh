#!/usr/bin/env bash
set -Eeuo pipefail

DISK=""
ESP_PART=""
BUILD_ROOT=""
RECOVER_FAT32_BACKUP=0
TMP=""
MOUNT_DIR=""
BACKUP_DIR=""

log() { printf '[openduet-linux] %s\n' "$*"; }
warn() { printf '[openduet-linux] WARNING: %s\n' "$*" >&2; }
die() { printf '[openduet-linux] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  set +e
  [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]] && mountpoint -q "$MOUNT_DIR" && umount "$MOUNT_DIR"
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'EOF'
Robust non-interactive OpenDuet installer for Linux.

Usage:
  sudo ./scripts/linux_install_openduet.sh \
    --disk /dev/sdX \
    --esp-part /dev/sdX1 \
    --build-root output/.../opencore-custom

Recovery after a broken upstream BootInstallBase.sh run:
  sudo ./scripts/linux_install_openduet.sh \
    --disk /dev/sdX \
    --esp-part /dev/sdX1 \
    --build-root output/.../opencore-custom \
    --recover-fat32-backup

This writes only:
  - the first 446 bytes of the disk MBR (boot0)
  - the first 512 bytes of the FAT ESP (boot1f32-derived PBR)
  - /boot on the FAT ESP

With --recover-fat32-backup, if the primary FAT32 boot sector is invalid but the
standard backup boot sector at sector 6 is valid, sector 6 is first copied back
to sector 0. Both sectors are backed up before that recovery write.

The GPT partition table and the installer partition are not rewritten.
EOF
}

need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }
while (($#)); do
  case "$1" in
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --esp-part) need_value "$@"; shift; ESP_PART="$1" ;;
    --build-root) need_value "$@"; shift; BUILD_ROOT="$1" ;;
    --recover-fat32-backup) RECOVER_FAT32_BACKUP=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ "$(uname -s)" == Linux ]] || die "Linux only"
[[ $EUID -eq 0 ]] || die "Run as root"
[[ -n "$DISK" && -n "$ESP_PART" && -n "$BUILD_ROOT" ]] || { usage; exit 2; }
[[ -b "$DISK" ]] || die "Not a block device: $DISK"
[[ "$(lsblk -dnro TYPE "$DISK" 2>/dev/null)" == disk ]] || die "Whole disk required: $DISK"
[[ -b "$ESP_PART" ]] || die "ESP partition does not exist: $ESP_PART"

BUILD_ROOT="$(readlink -f "$BUILD_ROOT")"
OD="$BUILD_ROOT/OpenDuet"
[[ -d "$OD" ]] || die "Missing OpenDuet directory: $OD"
[[ -f "$OD/boot0" ]] || die "Missing $OD/boot0"
[[ -f "$OD/boot1f32" ]] || die "Missing $OD/boot1f32"

BOOT_FILE=""
if [[ -f "$OD/bootIA32" && -f "$BUILD_ROOT/ESP/EFI/BOOT/BOOTIA32.efi" ]]; then
  BOOT_FILE="$OD/bootIA32"
elif [[ -f "$OD/bootX64" && -f "$BUILD_ROOT/ESP/EFI/BOOT/BOOTX64.efi" ]]; then
  BOOT_FILE="$OD/bootX64"
elif [[ -f "$OD/bootIA32" ]]; then
  BOOT_FILE="$OD/bootIA32"
elif [[ -f "$OD/bootX64" ]]; then
  BOOT_FILE="$OD/bootX64"
else
  die "No bootIA32/bootX64 file in $OD"
fi

parent="$(lsblk -no PKNAME "$ESP_PART" 2>/dev/null | head -n1 || true)"
if [[ -n "$parent" && "/dev/$parent" != "$DISK" ]]; then
  die "$ESP_PART does not belong to $DISK (parent=/dev/$parent)"
fi

unmount_esp() {
  local mp
  while IFS= read -r mp; do
    [[ -n "$mp" ]] || continue
    umount "$mp" 2>/dev/null || true
  done < <(findmnt -nr -S "$ESP_PART" -o TARGET 2>/dev/null || true)
}

wait_for_partition() {
  local i
  for i in $(seq 1 50); do
    [[ -b "$ESP_PART" ]] && return 0
    have udevadm && udevadm settle >/dev/null 2>&1 || true
    sleep 0.1
  done

  warn "$ESP_PART did not reappear quickly; asking kernel to reread partition table"
  have partprobe && partprobe "$DISK" >/dev/null 2>&1 || true
  have udevadm && udevadm settle >/dev/null 2>&1 || true

  for i in $(seq 1 50); do
    [[ -b "$ESP_PART" ]] && return 0
    sleep 0.1
  done
  return 1
}

fat32_sector_valid() {
  local sector="$1" type sig bps
  type="$(dd if="$ESP_PART" bs=1 skip=$((sector * 512 + 82)) count=8 status=none 2>/dev/null || true)"
  sig="$(dd if="$ESP_PART" bs=1 skip=$((sector * 512 + 510)) count=2 status=none 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  bps="$(dd if="$ESP_PART" bs=1 skip=$((sector * 512 + 11)) count=2 status=none 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [[ "$type" == FAT32* && "$sig" == 55aa && "$bps" == 0002 ]]
}

probe_fstype() {
  blkid -p -s TYPE -o value "$ESP_PART" 2>/dev/null || true
}

TMP="$(mktemp -d /tmp/openduet-linux.XXXXXX)"
MOUNT_DIR="$TMP/esp"
mkdir -p "$MOUNT_DIR"
BACKUP_DIR="$(pwd -P)/backup/openduet-$(date -u '+%Y%m%dT%H%M%SZ')-$(basename "$DISK")"
mkdir -p "$BACKUP_DIR"

unmount_esp

fstype="$(probe_fstype)"
case "$fstype" in
  vfat|fat|msdos) ;;
  "")
    if (( RECOVER_FAT32_BACKUP == 1 )) && fat32_sector_valid 6; then
      warn "Primary FAT32 boot sector is not recognised; valid backup boot sector found at sector 6"
      dd if="$ESP_PART" of="$BACKUP_DIR/esp-pbr-broken.bin" bs=512 count=1 status=none
      dd if="$ESP_PART" of="$BACKUP_DIR/esp-pbr-backup-sector6.bin" bs=512 skip=6 count=1 status=none
      log "Recovering primary FAT32 boot sector from sector 6"
      dd if="$BACKUP_DIR/esp-pbr-backup-sector6.bin" of="$ESP_PART" bs=512 count=1 conv=notrunc status=none
      sync
      have udevadm && udevadm settle >/dev/null 2>&1 || true
      fstype="$(probe_fstype)"
      case "$fstype" in
        vfat|fat|msdos) log "FAT32 boot-sector recovery succeeded" ;;
        *) die "Backup boot sector was written but FAT is still not recognised; backups are in $BACKUP_DIR" ;;
      esac
    elif (( RECOVER_FAT32_BACKUP == 1 )); then
      die "ESP is not recognised as FAT and sector 6 is not a valid FAT32 backup boot sector; no recovery write performed"
    else
      die "ESP is not FAT: $ESP_PART. If this follows the known broken upstream BootInstallBase.sh run, retry with --recover-fat32-backup"
    fi
    ;;
  *) die "ESP is not FAT: $ESP_PART ($fstype)" ;;
esac

# Capture both sectors before touching the disk. This avoids the upstream
# BootInstallBase.sh race where writing boot0 may temporarily make /dev/sdX1
# disappear before the original FAT PBR can be read.
dd if="$DISK" of="$BACKUP_DIR/mbr-before.bin" bs=512 count=1 status=none
dd if="$ESP_PART" of="$BACKUP_DIR/esp-pbr-before.bin" bs=512 count=1 status=none
cp "$BACKUP_DIR/esp-pbr-before.bin" "$TMP/origbs"
cp "$OD/boot1f32" "$TMP/newbs"

# Preserve FAT BPB/EBPB bytes 3..89 exactly as OpenCorePkg's upstream script does.
dd if="$TMP/origbs" of="$TMP/newbs" skip=3 seek=3 bs=1 count=87 conv=notrunc status=none
# Upstream randomises bytes 496..509 in the generated PBR.
dd if=/dev/urandom of="$TMP/newbs" skip=496 seek=496 bs=1 count=14 conv=notrunc status=none

log "Backup saved to $BACKUP_DIR"
log "Writing OpenDuet boot0 to first 446 bytes of $DISK"
dd if="$OD/boot0" of="$DISK" bs=1 count=446 conv=notrunc status=none
sync
have udevadm && udevadm settle >/dev/null 2>&1 || true

wait_for_partition || die "$ESP_PART did not return after MBR update; backups are in $BACKUP_DIR"
unmount_esp

log "Writing OpenDuet FAT PBR to $ESP_PART"
dd if="$TMP/newbs" of="$ESP_PART" bs=512 count=1 conv=notrunc status=none
sync
have udevadm && udevadm settle >/dev/null 2>&1 || true
wait_for_partition || die "$ESP_PART disappeared after PBR write; backups are in $BACKUP_DIR"

mount -t vfat -o rw,noatime "$ESP_PART" "$MOUNT_DIR"
cp --no-preserve=ownership,mode,timestamps "$BOOT_FILE" "$MOUNT_DIR/boot"
sync

[[ -f "$MOUNT_DIR/boot" ]] || die "Missing /boot after copy"
if [[ -f "$BUILD_ROOT/ESP/EFI/OC/config.plist" ]]; then
  [[ -f "$MOUNT_DIR/EFI/OC/config.plist" ]] || die "Existing EFI tree is missing EFI/OC/config.plist"
fi
if [[ -f "$BUILD_ROOT/ESP/Kernels/kernel" ]]; then
  [[ -f "$MOUNT_DIR/Kernels/kernel" ]] || die "Existing ESP is missing Kernels/kernel"
fi

umount "$MOUNT_DIR"
MOUNT_DIR=""

log "OpenDuet legacy boot sectors installed successfully"
log "Disk: $DISK"
log "ESP:  $ESP_PART"
log "Boot: $(basename "$BOOT_FILE")"