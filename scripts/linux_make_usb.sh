#!/usr/bin/env bash
# Experimental Linux deployment backend for legacy OpenCore/OpenDuet installers.
# It intentionally uses OpenCorePkg's own Utilities/LegacyBoot installer for
# the MBR/PBR step instead of reimplementing boot0/boot1f32 writes.
set -Eeuo pipefail

MODE=""
DISK=""
RETAIL=""
BUILD_ROOT=""
AMD_KERNEL=""
ESP_PART=""
INSTALLER_PART=""
ALLOW_INTERNAL=0
DRY_RUN=0
INSTALLER_LABEL="INSTALLER"

TEMP_DIR=""
SOURCE_LOOP=""
SOURCE_MOUNT=""
ESP_MOUNT=""
INSTALLER_MOUNT=""
CONVERTED_IMAGE=""

usage() {
  cat <<'USAGE'
Linux legacy macOS USB backend (EXPERIMENTAL)

Create a fresh GPT USB (destructive):
  sudo ./scripts/linux_make_usb.sh --make-usb \
    --disk /dev/sdX \
    --retail /path/to/SnowLeopard-Retail.iso-or-dmg \
    --build-root output/targets/emachines-d640-n930/snowleopard/opencore \
    --amd-kernel /path/to/legacy_amd_mach_kernel

Update only EFI/OpenDuet on an existing GPT disk:
  sudo ./scripts/linux_make_usb.sh --update-efi \
    --disk /dev/sdX \
    --build-root output/targets/emachines-d640-n930/snowleopard/opencore

Read-only helpers:
  ./scripts/linux_make_usb.sh --list-disks
  sudo ./scripts/linux_make_usb.sh --verify --disk /dev/sdX

Options:
  --esp-part /dev/sdX1          Override automatically detected EFI partition.
  --installer-part /dev/sdX2    Override automatically detected installer partition.
  --label NAME                  HFS+ label for a fresh installer (default INSTALLER).
  --allow-internal              Permit a non-removable/non-USB target (root disk is never allowed).
  --dry-run                     Print the destructive plan without writing.

Linux requirements for full creation:
  util-linux (lsblk, mount, findmnt, losetup, blkid), gdisk/sgdisk,
  dosfstools (mkfs.vfat), hfsprogs (mkfs.hfsplus), rsync, fdisk,
  uuidgen, and dmg2img when the retail source is a compressed DMG.

The full HFS+ restore path is experimental. OpenCore's official LegacyBoot
BootInstallBase.sh supports Linux natively; this script delegates the boot0 /
boot1f32 / OpenDuet installation to that upstream tool.
USAGE
}

log() { printf '[linux-usb] %s\n' "$*"; }
warn() { printf '[linux-usb] WARNING: %s\n' "$*" >&2; }
die() { printf '[linux-usb] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  set +e
  [[ -n "$ESP_MOUNT" ]] && mountpoint -q "$ESP_MOUNT" && umount "$ESP_MOUNT"
  [[ -n "$INSTALLER_MOUNT" ]] && mountpoint -q "$INSTALLER_MOUNT" && umount "$INSTALLER_MOUNT"
  [[ -n "$SOURCE_MOUNT" ]] && mountpoint -q "$SOURCE_MOUNT" && umount "$SOURCE_MOUNT"
  [[ -n "$SOURCE_LOOP" ]] && losetup "$SOURCE_LOOP" >/dev/null 2>&1 && losetup -d "$SOURCE_LOOP"
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

set_mode() {
  [[ -z "$MODE" || "$MODE" == "$1" ]] || die "Choose exactly one operation"
  MODE="$1"
}

need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }

while (($#)); do
  case "$1" in
    --make-usb) set_mode make-usb ;;
    --update-efi) set_mode update-efi ;;
    --verify) set_mode verify ;;
    --list-disks) set_mode list-disks ;;
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --retail) need_value "$@"; shift; RETAIL="$1" ;;
    --build-root) need_value "$@"; shift; BUILD_ROOT="$1" ;;
    --amd-kernel) need_value "$@"; shift; AMD_KERNEL="$1" ;;
    --esp-part) need_value "$@"; shift; ESP_PART="$1" ;;
    --installer-part) need_value "$@"; shift; INSTALLER_PART="$1" ;;
    --label) need_value "$@"; shift; INSTALLER_LABEL="$1" ;;
    --allow-internal) ALLOW_INTERNAL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ "$(uname -s)" == Linux ]] || die "This backend runs on Linux only"

if [[ "$MODE" == list-disks ]]; then
  lsblk -d -o NAME,PATH,SIZE,MODEL,TRAN,RM,RO,TYPE
  exit 0
fi

[[ -n "$MODE" ]] || { usage; exit 2; }
[[ -n "$DISK" ]] || die "--disk is required"
[[ -b "$DISK" ]] || die "Not a block device: $DISK"
[[ "$(lsblk -dnro TYPE "$DISK")" == disk ]] || die "Whole disk required, not a partition: $DISK"

root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
root_parent=""
if [[ -n "$root_source" && -b "$root_source" ]]; then
  root_parent="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
  [[ -n "$root_parent" ]] && root_parent="/dev/$root_parent"
fi
[[ "$DISK" != "$root_source" && "$DISK" != "$root_parent" ]] \
  || die "Refusing to operate on the Linux root disk: $DISK"

rm_flag="$(lsblk -dnro RM "$DISK" | tr -d ' ')"
transport="$(lsblk -dnro TRAN "$DISK" | tr -d ' ')"
if [[ "$ALLOW_INTERNAL" -ne 1 && "$rm_flag" != 1 && "$transport" != usb ]]; then
  die "$DISK is not clearly removable/USB (RM=$rm_flag TRAN=${transport:-unknown}); use --allow-internal only after manual verification"
fi

partition_path() {
  local number="$1"
  lsblk -lnpo NAME,PARTN "$DISK" | awk -v n="$number" '$2 == n {print $1; exit}'
}

settle_partitions() {
  have partprobe && partprobe "$DISK" >/dev/null 2>&1 || true
  have udevadm && udevadm settle || true
  sleep 1
}

unmount_children() {
  local target
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    umount "$target" 2>/dev/null || true
  done < <(lsblk -lnpo MOUNTPOINTS "$DISK" | awk 'NF')
}

assert_build_root() {
  [[ -n "$BUILD_ROOT" ]] || die "--build-root is required"
  BUILD_ROOT="$(readlink -f "$BUILD_ROOT")"
  [[ -f "$BUILD_ROOT/ESP/EFI/OC/config.plist" ]] || die "Missing OpenCore config under $BUILD_ROOT/ESP"
  [[ -d "$BUILD_ROOT/OpenDuet" ]] || die "Missing OpenDuet staging directory: $BUILD_ROOT/OpenDuet"
  [[ -f "$BUILD_ROOT/OpenDuet/BootInstallBase.sh" ]] || die "Missing upstream BootInstallBase.sh"
  if [[ -f "$BUILD_ROOT/OpenDuet/BootInstall_IA32.tool" ]]; then
    BOOT_TOOL="$BUILD_ROOT/OpenDuet/BootInstall_IA32.tool"
  elif [[ -f "$BUILD_ROOT/OpenDuet/BootInstall_X64.tool" ]]; then
    BOOT_TOOL="$BUILD_ROOT/OpenDuet/BootInstall_X64.tool"
  else
    die "No BootInstall_IA32.tool or BootInstall_X64.tool in $BUILD_ROOT/OpenDuet"
  fi
}

confirm_exact() {
  local expected="$1" answer
  printf 'Type exactly: %s\n> ' "$expected"
  IFS= read -r answer
  [[ "$answer" == "$expected" ]] || die "Confirmation mismatch; nothing was changed"
}

mount_esp() {
  local part="$1"
  ESP_MOUNT="$TEMP_DIR/esp"
  mkdir -p "$ESP_MOUNT"
  mount -t vfat -o rw,noatime "$part" "$ESP_MOUNT"
}

copy_efi_tree() {
  local part="$1" backup_dir
  mount_esp "$part"
  backup_dir="$(pwd -P)/backup/linux-efi-$(date -u '+%Y%m%dT%H%M%SZ')-$(basename "$DISK")"
  if [[ -d "$ESP_MOUNT/EFI" || -f "$ESP_MOUNT/boot" ]]; then
    mkdir -p "$backup_dir"
    [[ -d "$ESP_MOUNT/EFI" ]] && cp -a "$ESP_MOUNT/EFI" "$backup_dir/EFI"
    [[ -f "$ESP_MOUNT/boot" ]] && cp -a "$ESP_MOUNT/boot" "$backup_dir/boot"
    log "Backed up existing EFI/OpenDuet files to $backup_dir"
  fi
  rm -rf -- "$ESP_MOUNT/EFI"
  cp -a "$BUILD_ROOT/ESP/EFI" "$ESP_MOUNT/EFI"
  [[ -f "$BUILD_ROOT/ESP/boot" ]] && cp -a "$BUILD_ROOT/ESP/boot" "$ESP_MOUNT/boot"
  sync
  umount "$ESP_MOUNT"
}

install_openduet() {
  local disk_name part_name
  disk_name="$(basename "$DISK")"
  part_name="$(basename "$ESP_PART")"
  chmod +x "$BOOT_TOOL" "$BUILD_ROOT/OpenDuet/BootInstallBase.sh"
  log "Installing OpenDuet using OpenCorePkg's upstream Linux-capable BootInstall tool"
  (
    cd "$BUILD_ROOT/OpenDuet"
    printf '%s\n%s\n' "$disk_name" "$part_name" | "$BOOT_TOOL"
  )

  # Upstream BootInstallBase.sh mounts the EFI partition on Linux so it can
  # copy boot{IA32,X64}, but it intentionally leaves that mount available for
  # inspection.  Our non-interactive flow needs the partition free for the
  # read-only verification pass and for reliable cleanup.
  sync
  local mp
  while IFS= read -r mp; do
    [[ -n "$mp" ]] || continue
    umount "$mp" 2>/dev/null || true
  done < <(lsblk -nro MOUNTPOINTS "$ESP_PART" | awk 'NF')
}

verify_target() {
  local ok=1 tmp
  [[ -n "$ESP_PART" ]] || ESP_PART="$(partition_path 1)"
  [[ -n "$INSTALLER_PART" ]] || INSTALLER_PART="$(partition_path 2)"
  printf 'Disk: %s\n' "$DISK"
  lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,PARTLABEL,PARTTYPE,MOUNTPOINTS "$DISK"

  TEMP_DIR="${TEMP_DIR:-$(mktemp -d /tmp/legacy-macos-usb.XXXXXX)}"
  if [[ -n "$ESP_PART" && -b "$ESP_PART" ]]; then
    tmp="$TEMP_DIR/verify-esp"; mkdir -p "$tmp"
    if mount -o ro "$ESP_PART" "$tmp"; then
      [[ -f "$tmp/EFI/OC/config.plist" ]] && printf 'PASS EFI/OC/config.plist\n' || { printf 'FAIL EFI/OC/config.plist\n'; ok=0; }
      [[ -f "$tmp/boot" ]] && printf 'PASS OpenDuet /boot\n' || { printf 'FAIL OpenDuet /boot\n'; ok=0; }
      umount "$tmp"
    else
      printf 'FAIL mounting EFI partition\n'; ok=0
    fi
  fi
  if [[ -n "$INSTALLER_PART" && -b "$INSTALLER_PART" ]]; then
    tmp="$TEMP_DIR/verify-installer"; mkdir -p "$tmp"
    if mount -o ro "$INSTALLER_PART" "$tmp"; then
      [[ -f "$tmp/System/Library/CoreServices/boot.efi" ]] && printf 'PASS installer boot.efi\n' || { printf 'WARN installer boot.efi not found\n'; ok=0; }
      [[ -f "$tmp/mach_kernel" ]] && printf 'PASS /mach_kernel\n' || { printf 'WARN /mach_kernel not found\n'; ok=0; }
      umount "$tmp"
    else
      printf 'FAIL mounting installer partition\n'; ok=0
    fi
  fi
  (( ok == 1 ))
}

if [[ "$MODE" == verify ]]; then
  [[ $EUID -eq 0 ]] || die "--verify requires root to mount partitions read-only"
  TEMP_DIR="$(mktemp -d /tmp/legacy-macos-usb.XXXXXX)"
  verify_target
  exit $?
fi

[[ $EUID -eq 0 ]] || die "$MODE requires root"
assert_build_root
TEMP_DIR="$(mktemp -d /tmp/legacy-macos-usb.XXXXXX)"

if [[ "$MODE" == update-efi ]]; then
  settle_partitions
  [[ -n "$ESP_PART" ]] || ESP_PART="$(partition_path 1)"
  [[ -n "$ESP_PART" && -b "$ESP_PART" ]] || die "Could not identify EFI partition; pass --esp-part"
  fstype="$(blkid -s TYPE -o value "$ESP_PART" 2>/dev/null || true)"
  [[ "$fstype" == vfat || "$fstype" == msdos || "$fstype" == fat ]] || die "EFI partition is not FAT: $ESP_PART ($fstype)"
  if (( DRY_RUN == 1 )); then
    printf 'DRY RUN: would replace EFI/OpenDuet on %s and reinstall legacy boot sectors on %s\n' "$ESP_PART" "$DISK"
    exit 0
  fi
  confirm_exact "UPDATE EFI $ESP_PART ON $DISK"
  unmount_children
  copy_efi_tree "$ESP_PART"
  install_openduet
  sync
  verify_target
  exit $?
fi

[[ "$MODE" == make-usb ]] || die "Unexpected mode: $MODE"
[[ -n "$RETAIL" && -e "$RETAIL" ]] || die "--retail must point to an existing ISO/DMG/image/directory"
[[ -n "$AMD_KERNEL" && -f "$AMD_KERNEL" ]] || die "The D640 path requires --amd-kernel pointing to a user-supplied Snow Leopard AMD K10 kernel"

for cmd in lsblk findmnt losetup blkid sgdisk mkfs.vfat mkfs.hfsplus rsync fdisk uuidgen dd mount umount; do
  have "$cmd" || die "Missing required command: $cmd"
done

if (( DRY_RUN == 1 )); then
  cat <<PLAN
DRY RUN — no disk writes were performed.
Target: $DISK
Retail: $RETAIL
Build:  $BUILD_ROOT
Kernel: $AMD_KERNEL
Would:
  1. wipe $DISK and create GPT
  2. create 200 MiB FAT32 EFI partition + HFS+ installer partition
  3. restore/copy the retail installer from Linux
  4. replace /mach_kernel with the supplied AMD kernel
  5. copy OpenCore EFI and run OpenCorePkg's Linux LegacyBoot installer
PLAN
  exit 0
fi

printf 'WARNING: all data on %s will be destroyed.\n' "$DISK"
lsblk -o NAME,PATH,SIZE,MODEL,TRAN,RM,FSTYPE,LABEL,MOUNTPOINTS "$DISK"
confirm_exact "ERASE $DISK"
unmount_children

log "Creating GPT layout"
sgdisk --zap-all "$DISK"
sgdisk -n 1:2048:+200M -t 1:EF00 -c 1:OPENCORE "$DISK"
sgdisk -n 2:0:0 -t 2:AF00 -c 2:"$INSTALLER_LABEL" "$DISK"
settle_partitions
ESP_PART="${ESP_PART:-$(partition_path 1)}"
INSTALLER_PART="${INSTALLER_PART:-$(partition_path 2)}"
[[ -b "$ESP_PART" && -b "$INSTALLER_PART" ]] || die "Partition discovery failed after GPT creation"

log "Formatting $ESP_PART as FAT32"
mkfs.vfat -F 32 -n OPENCORE "$ESP_PART"
log "Formatting $INSTALLER_PART as HFS+"
mkfs.hfsplus -v "$INSTALLER_LABEL" "$INSTALLER_PART"

SOURCE_MOUNT="$TEMP_DIR/source"
INSTALLER_MOUNT="$TEMP_DIR/installer"
mkdir -p "$SOURCE_MOUNT" "$INSTALLER_MOUNT"

prepare_source_image() {
  local source="$1" image="$1" ext candidate fstype
  if [[ -d "$source" ]]; then
    SOURCE_MOUNT="$(readlink -f "$source")"
    return 0
  fi

  ext="${source##*.}"
  ext="${ext,,}"
  if [[ "$ext" == dmg ]]; then
    have dmg2img || die "Compressed DMG support requires dmg2img"
    CONVERTED_IMAGE="$TEMP_DIR/retail.raw"
    log "Converting DMG to raw image with dmg2img"
    dmg2img "$source" "$CONVERTED_IMAGE" >/dev/null
    image="$CONVERTED_IMAGE"
  fi

  SOURCE_LOOP="$(losetup --find --show --partscan --read-only "$image")"
  have udevadm && udevadm settle || true

  while read -r candidate fstype; do
    [[ -n "$candidate" ]] || continue
    case "$fstype" in
      hfsplus|hfs|iso9660|udf)
        if mount -o ro "$candidate" "$SOURCE_MOUNT" 2>/dev/null; then
          if [[ -f "$SOURCE_MOUNT/System/Library/CoreServices/boot.efi" || -d "$SOURCE_MOUNT/System/Installation" ]]; then
            log "Retail source mounted from $candidate ($fstype)"
            return 0
          fi
          umount "$SOURCE_MOUNT"
        fi
        ;;
    esac
  done < <(lsblk -rno PATH,FSTYPE "$SOURCE_LOOP")

  die "Could not find a mountable Snow Leopard volume inside $source"
}

prepare_source_image "$RETAIL"
mount -t hfsplus -o rw,noatime "$INSTALLER_PART" "$INSTALLER_MOUNT"

warn "Linux HFS+ filesystem copying is experimental; verify the finished USB before booting it."
log "Copying retail installer to HFS+ target"
rsync -aH --numeric-ids --info=progress2 "$SOURCE_MOUNT"/ "$INSTALLER_MOUNT"/

if [[ -f "$INSTALLER_MOUNT/mach_kernel" && ! -e "$INSTALLER_MOUNT/mach_kernel.original" ]]; then
  cp -a "$INSTALLER_MOUNT/mach_kernel" "$INSTALLER_MOUNT/mach_kernel.original"
fi
cp -f "$AMD_KERNEL" "$INSTALLER_MOUNT/mach_kernel"
chmod 0644 "$INSTALLER_MOUNT/mach_kernel"
sync
umount "$INSTALLER_MOUNT"

copy_efi_tree "$ESP_PART"
install_openduet
sync

log "USB creation completed; running read-only verification"
verify_target
