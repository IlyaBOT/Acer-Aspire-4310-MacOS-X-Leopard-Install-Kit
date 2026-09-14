#!/usr/bin/env bash
# Experimental Linux deployment backend for legacy OpenCore/OpenDuet installers.
# OpenDuet installation is delegated to OpenCorePkg's own Linux-capable LegacyBoot tool.
set -Eeuo pipefail

MODE=""
DISK=""
RETAIL=""
BUILD_ROOT=""
AMD_KERNEL=""
ESP_PART=""
INSTALLER_PART=""
EXPECTED_KERNEL_VERSION=""
RESTORE_MODE="auto"
ALLOW_INTERNAL=0
DRY_RUN=0
INSTALLER_LABEL="INSTALLER"

TEMP_DIR=""
SOURCE_LOOP=""
SOURCE_MOUNT=""
SOURCE_BLOCK_DEVICE=""
SOURCE_FSTYPE=""
SOURCE_IS_DIR=0
ESP_MOUNT=""
INSTALLER_MOUNT=""
CONVERTED_IMAGE=""
BOOT_TOOL=""

usage() {
  cat <<'USAGE'
Linux legacy macOS USB backend (EXPERIMENTAL)

Inspect a retail image without modifying a disk:
  sudo ./scripts/linux_make_usb.sh --inspect-retail --retail SnowLeopard10.6.3.iso

Create a fresh GPT USB (destructive):
  sudo ./scripts/linux_make_usb.sh --make-usb \
    --disk /dev/sdX \
    --retail /path/to/SnowLeopard10.6.3.iso \
    --build-root output/targets/emachines-d640-n930/snowleopard/opencore \
    --amd-kernel downloads/amd-kernels/10.6.3/legacy_kernel \
    --expected-kernel-version 10.3.0

Update only EFI/OpenDuet on an existing GPT disk:
  sudo ./scripts/linux_make_usb.sh --update-efi \
    --disk /dev/sdX --build-root output/targets/emachines-d640-n930/snowleopard/opencore

Read-only helpers:
  ./scripts/linux_make_usb.sh --list-disks
  sudo ./scripts/linux_make_usb.sh --verify --disk /dev/sdX --expected-kernel-version 10.3.0

Options:
  --restore-mode auto|block|files
      auto  : prefer a block-level HFS/HFS+ clone, fall back to file copy
      block : require a real HFS/HFS+ source block device inside the ISO/DMG
      files : create HFS+ and copy files with rsync (experimental fallback)
  --esp-part /dev/sdX1
  --installer-part /dev/sdX2
  --label NAME
  --allow-internal
  --dry-run

Linux requirements:
  util-linux (lsblk, mount, findmnt, losetup, blkid, blockdev), gdisk/sgdisk,
  dosfstools, hfsprogs, rsync, fdisk, uuidgen, dd; dmg2img for compressed DMG.

The block-clone path is intentionally preferred because it preserves the source
HFS+ filesystem and metadata more closely than a Linux file copy. File-copy mode
remains available for ISO/UDF images where no HFS block device can be exposed.
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
  [[ -n "$SOURCE_MOUNT" && -d "$SOURCE_MOUNT" ]] && mountpoint -q "$SOURCE_MOUNT" && umount "$SOURCE_MOUNT"
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
    --inspect-retail) set_mode inspect-retail ;;
    --list-disks) set_mode list-disks ;;
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --retail) need_value "$@"; shift; RETAIL="$1" ;;
    --build-root) need_value "$@"; shift; BUILD_ROOT="$1" ;;
    --amd-kernel) need_value "$@"; shift; AMD_KERNEL="$1" ;;
    --expected-kernel-version) need_value "$@"; shift; EXPECTED_KERNEL_VERSION="$1" ;;
    --restore-mode) need_value "$@"; shift; RESTORE_MODE="$1" ;;
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

case "$RESTORE_MODE" in auto|block|files) ;; *) die "--restore-mode must be auto, block, or files" ;; esac
[[ "$(uname -s)" == Linux ]] || die "This backend runs on Linux only"

if [[ "$MODE" == list-disks ]]; then
  lsblk -d -o NAME,PATH,SIZE,MODEL,TRAN,RM,RO,TYPE
  exit 0
fi

[[ -n "$MODE" ]] || { usage; exit 2; }

prepare_temp() {
  [[ -n "$TEMP_DIR" ]] || TEMP_DIR="$(mktemp -d /tmp/legacy-macos-usb.XXXXXX)"
  SOURCE_MOUNT="$TEMP_DIR/source"
  INSTALLER_MOUNT="$TEMP_DIR/installer"
  mkdir -p "$SOURCE_MOUNT" "$INSTALLER_MOUNT"
}

source_has_installer_markers() {
  local root="$1"
  [[ -f "$root/System/Library/CoreServices/boot.efi" || -d "$root/System/Installation" ]]
}

try_source_candidate() {
  local candidate="$1" fstype="$2"
  umount "$SOURCE_MOUNT" 2>/dev/null || true
  if mount -o ro "$candidate" "$SOURCE_MOUNT" 2>/dev/null; then
    if source_has_installer_markers "$SOURCE_MOUNT"; then
      SOURCE_FSTYPE="$fstype"
      case "$fstype" in hfsplus|hfs) SOURCE_BLOCK_DEVICE="$candidate" ;; *) SOURCE_BLOCK_DEVICE="" ;; esac
      log "Retail installer found on $candidate ($fstype)"
      return 0
    fi
    umount "$SOURCE_MOUNT" 2>/dev/null || true
  fi
  return 1
}

prepare_source_image() {
  local source="$1" image="$1" ext candidate fstype
  [[ -e "$source" ]] || die "Retail source does not exist: $source"
  prepare_temp

  if [[ -d "$source" ]]; then
    SOURCE_IS_DIR=1
    SOURCE_MOUNT="$(readlink -f "$source")"
    source_has_installer_markers "$SOURCE_MOUNT" || die "Directory does not look like a Snow Leopard installer: $source"
    SOURCE_FSTYPE="directory"
    return 0
  fi

  [[ $EUID -eq 0 ]] || die "Image inspection requires root because losetup is used"
  ext="${source##*.}"; ext="${ext,,}"
  if [[ "$ext" == dmg ]]; then
    have dmg2img || die "Compressed DMG support requires dmg2img"
    CONVERTED_IMAGE="$TEMP_DIR/retail.raw"
    log "Converting DMG to raw image with dmg2img"
    dmg2img "$source" "$CONVERTED_IMAGE" >/dev/null
    image="$CONVERTED_IMAGE"
  fi

  SOURCE_LOOP="$(losetup --find --show --partscan --read-only "$image")"
  have udevadm && udevadm settle || true

  # Prefer a native HFS/HFS+ representation when hybrid optical images expose one.
  while read -r candidate fstype; do
    [[ -n "$candidate" ]] || continue
    case "$fstype" in hfsplus|hfs) try_source_candidate "$candidate" "$fstype" && return 0 ;; esac
  done < <(lsblk -rno PATH,FSTYPE "$SOURCE_LOOP")

  # Fallback to an ISO/UDF view. This is usable only with the file-copy restore path.
  while read -r candidate fstype; do
    [[ -n "$candidate" ]] || continue
    case "$fstype" in iso9660|udf) try_source_candidate "$candidate" "$fstype" && return 0 ;; esac
  done < <(lsblk -rno PATH,FSTYPE "$SOURCE_LOOP")

  die "Could not find a mountable Snow Leopard installer volume inside $source"
}

print_source_report() {
  printf 'Retail: %s\n' "$RETAIL"
  printf 'Detected filesystem view: %s\n' "$SOURCE_FSTYPE"
  if [[ -n "$SOURCE_BLOCK_DEVICE" ]]; then
    printf 'HFS block source: %s\n' "$SOURCE_BLOCK_DEVICE"
    printf 'Preferred restore: block\n'
    blockdev --getsize64 "$SOURCE_BLOCK_DEVICE" 2>/dev/null | awk '{printf "Source bytes: %s\n",$1}' || true
  else
    printf 'HFS block source: none\n'
    printf 'Preferred restore: files (experimental fallback)\n'
  fi
  if [[ -f "$SOURCE_MOUNT/System/Library/CoreServices/boot.efi" ]]; then
    printf 'PASS installer boot.efi\n'
  else
    printf 'WARN installer boot.efi not visible\n'
  fi
  if [[ -f "$SOURCE_MOUNT/mach_kernel" ]]; then
    printf 'Retail /mach_kernel: present\n'
  else
    printf 'Retail /mach_kernel: not visible\n'
  fi
}

if [[ "$MODE" == inspect-retail ]]; then
  [[ -n "$RETAIL" ]] || die "--inspect-retail requires --retail"
  prepare_source_image "$RETAIL"
  print_source_report
  exit 0
fi

[[ -n "$DISK" ]] || die "--disk is required"
[[ -b "$DISK" ]] || die "Not a block device: $DISK"
[[ "$(lsblk -dnro TYPE "$DISK")" == disk ]] || die "Whole disk required, not a partition: $DISK"

root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
root_parent=""
if [[ -n "$root_source" && -b "$root_source" ]]; then
  root_parent="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
  [[ -n "$root_parent" ]] && root_parent="/dev/$root_parent"
fi
[[ "$DISK" != "$root_source" && "$DISK" != "$root_parent" ]] || die "Refusing to operate on the Linux root disk: $DISK"

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
  mkdir -p "$ESP_MOUNT/EFI"
  # FAT does not support Unix uid/gid/mode metadata. Avoid cp -a here: when
  # running as root GNU cp tries to restore ownership and aborts with EPERM.
  # Copy the complete tree (including .contentVisibility/.contentFlavour)
  # while deliberately discarding metadata FAT cannot represent.
  cp -R --no-preserve=ownership,mode,timestamps "$BUILD_ROOT/ESP/EFI"/. "$ESP_MOUNT/EFI"/
  if [[ -f "$BUILD_ROOT/ESP/boot" ]]; then
    cp --no-preserve=ownership,mode,timestamps "$BUILD_ROOT/ESP/boot" "$ESP_MOUNT/boot"
  fi
  [[ -f "$ESP_MOUNT/EFI/OC/config.plist" ]] || die "EFI copy failed: missing EFI/OC/config.plist"
  [[ -f "$ESP_MOUNT/EFI/BOOT/BOOTIA32.efi" ]] || die "EFI copy failed: missing EFI/BOOT/BOOTIA32.efi"
  sync
  umount "$ESP_MOUNT"
}

install_openduet() {
  local disk_name part_name mp
  disk_name="$(basename "$DISK")"
  part_name="$(basename "$ESP_PART")"
  chmod +x "$BOOT_TOOL" "$BUILD_ROOT/OpenDuet/BootInstallBase.sh"
  log "Installing OpenDuet using OpenCorePkg's upstream Linux LegacyBoot installer"
  (
    cd "$BUILD_ROOT/OpenDuet"
    printf '%s\n%s\n' "$disk_name" "$part_name" | "$BOOT_TOOL"
  )
  sync
  while IFS= read -r mp; do
    [[ -n "$mp" ]] || continue
    umount "$mp" 2>/dev/null || true
  done < <(lsblk -nro MOUNTPOINTS "$ESP_PART" | awk 'NF')
}

kernel_version_ok() {
  local path="$1"
  [[ -n "$EXPECTED_KERNEL_VERSION" ]] || return 0
  LC_ALL=C grep -aFq "Darwin Kernel Version $EXPECTED_KERNEL_VERSION" "$path" 2>/dev/null
}

verify_target() {
  local ok=1 tmp
  [[ -n "$ESP_PART" ]] || ESP_PART="$(partition_path 1)"
  [[ -n "$INSTALLER_PART" ]] || INSTALLER_PART="$(partition_path 2)"
  printf 'Disk: %s\n' "$DISK"
  lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,PARTLABEL,PARTTYPE,MOUNTPOINTS "$DISK"

  prepare_temp
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
      if [[ -f "$tmp/mach_kernel" ]]; then
        printf 'PASS /mach_kernel\n'
        if [[ -n "$EXPECTED_KERNEL_VERSION" ]]; then
          kernel_version_ok "$tmp/mach_kernel" && printf 'PASS kernel Darwin %s\n' "$EXPECTED_KERNEL_VERSION" \
            || { printf 'FAIL kernel is not Darwin %s\n' "$EXPECTED_KERNEL_VERSION"; ok=0; }
        fi
      else
        printf 'WARN /mach_kernel not found\n'; ok=0
      fi
      umount "$tmp"
    else
      printf 'FAIL mounting installer partition\n'; ok=0
    fi
  fi
  (( ok == 1 ))
}

if [[ "$MODE" == verify ]]; then
  [[ $EUID -eq 0 ]] || die "--verify requires root to mount partitions read-only"
  prepare_temp
  verify_target
  exit $?
fi

[[ $EUID -eq 0 ]] || die "$MODE requires root"
assert_build_root
prepare_temp

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
[[ -n "$AMD_KERNEL" && -f "$AMD_KERNEL" ]] || die "--amd-kernel must point to the verified Snow Leopard AMD kernel"

for cmd in lsblk findmnt losetup blkid sgdisk mkfs.vfat rsync fdisk uuidgen dd mount umount blockdev strings; do
  have "$cmd" || die "Missing required command: $cmd"
done

# Inspect and validate the retail image before any destructive operation.
prepare_source_image "$RETAIL"
print_source_report

SELECTED_RESTORE="$RESTORE_MODE"
if [[ "$SELECTED_RESTORE" == auto ]]; then
  [[ -n "$SOURCE_BLOCK_DEVICE" ]] && SELECTED_RESTORE=block || SELECTED_RESTORE=files
fi
if [[ "$SELECTED_RESTORE" == block && -z "$SOURCE_BLOCK_DEVICE" ]]; then
  die "--restore-mode block requested, but the image exposes no HFS/HFS+ installer block device"
fi
if [[ "$SELECTED_RESTORE" == files ]]; then
  have mkfs.hfsplus || die "File-copy restore requires mkfs.hfsplus (hfsprogs)"
fi

if (( DRY_RUN == 1 )); then
  cat <<PLAN
DRY RUN — no disk writes were performed.
Target: $DISK
Retail: $RETAIL
Build:  $BUILD_ROOT
Kernel: $AMD_KERNEL
Restore mode selected: $SELECTED_RESTORE
Would:
  1. wipe $DISK and create GPT
  2. create 200 MiB FAT32 EFI partition + installer partition
  3. restore the retail installer using $SELECTED_RESTORE mode
  4. back up retail /mach_kernel and install the AMD kernel
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

mount_hfs_rw() {
  local part="$1"
  umount "$INSTALLER_MOUNT" 2>/dev/null || true
  if mount -t hfsplus -o rw,force,noatime "$part" "$INSTALLER_MOUNT" 2>/dev/null; then return 0; fi
  mount -t hfsplus -o rw,noatime "$part" "$INSTALLER_MOUNT"
}

install_amd_kernel() {
  if [[ -f "$INSTALLER_MOUNT/mach_kernel" && ! -e "$INSTALLER_MOUNT/mach_kernel.original" ]]; then
    cp -a "$INSTALLER_MOUNT/mach_kernel" "$INSTALLER_MOUNT/mach_kernel.original"
  fi
  cp -f "$AMD_KERNEL" "$INSTALLER_MOUNT/mach_kernel"
  chmod 0644 "$INSTALLER_MOUNT/mach_kernel"
  sync
  kernel_version_ok "$INSTALLER_MOUNT/mach_kernel" \
    || die "Installed kernel does not match expected Darwin version $EXPECTED_KERNEL_VERSION"
}

restore_block() {
  local source_bytes target_bytes
  source_bytes="$(blockdev --getsize64 "$SOURCE_BLOCK_DEVICE")"
  target_bytes="$(blockdev --getsize64 "$INSTALLER_PART")"
  if (( source_bytes > target_bytes )); then
    if [[ "$RESTORE_MODE" == auto ]]; then
      warn "HFS source is larger than target partition; falling back to file-copy restore"
      SELECTED_RESTORE=files
      return 2
    fi
    die "HFS source ($source_bytes bytes) is larger than installer partition ($target_bytes bytes)"
  fi

  mountpoint -q "$SOURCE_MOUNT" && umount "$SOURCE_MOUNT"
  log "Cloning HFS source block device $SOURCE_BLOCK_DEVICE -> $INSTALLER_PART"
  dd if="$SOURCE_BLOCK_DEVICE" of="$INSTALLER_PART" bs=16M status=progress conv=fsync
  sync
  if have fsck.hfsplus; then
    fsck.hfsplus -fy "$INSTALLER_PART" >/dev/null 2>&1 || warn "fsck.hfsplus reported issues after clone"
  else
    warn "fsck.hfsplus is unavailable; skipping HFS consistency check"
  fi
  mount_hfs_rw "$INSTALLER_PART"
  source_has_installer_markers "$INSTALLER_MOUNT" || die "Block-cloned volume does not expose installer markers"
  install_amd_kernel
  umount "$INSTALLER_MOUNT"
}

restore_files() {
  log "Formatting $INSTALLER_PART as HFS+ for file-copy fallback"
  mkfs.hfsplus -v "$INSTALLER_LABEL" "$INSTALLER_PART"
  mount_hfs_rw "$INSTALLER_PART"
  warn "File-copy restore is an experimental fallback; HFS+ metadata may differ from Apple's asr restore."
  log "Copying retail installer files to HFS+ target"
  rsync -aH --numeric-ids --info=progress2 "$SOURCE_MOUNT"/ "$INSTALLER_MOUNT"/
  source_has_installer_markers "$INSTALLER_MOUNT" || die "Copied volume does not expose installer markers"
  install_amd_kernel
  umount "$INSTALLER_MOUNT"
}

if [[ "$SELECTED_RESTORE" == block ]]; then
  if restore_block; then
    :
  else
    status=$?
    if [[ $status -eq 2 && "$SELECTED_RESTORE" == files ]]; then
      # The size check returns before unmounting the source, so it remains
      # available for the explicit file-copy fallback.
      restore_files
    else
      exit "$status"
    fi
  fi
else
  restore_files
fi

copy_efi_tree "$ESP_PART"
install_openduet
sync

log "USB creation completed; running read-only verification"
verify_target
