#!/usr/bin/env bash
# Safe Linux EFI/OpenDuet updater for an existing legacy macOS installer USB.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DISK=""
ESP_PART=""
BUILD_ROOT=""
ALLOW_INTERNAL=0
DRY_RUN=0
ESP_MOUNT=""

log() { printf '[linux-update-efi] %s\n' "$*"; }
warn() { printf '[linux-update-efi] WARNING: %s\n' "$*" >&2; }
die() { printf '[linux-update-efi] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  set +e
  [[ -n "$ESP_MOUNT" && -d "$ESP_MOUNT" ]] && mountpoint -q "$ESP_MOUNT" && umount "$ESP_MOUNT"
  [[ -n "$ESP_MOUNT" && -d "$ESP_MOUNT" ]] && rmdir "$ESP_MOUNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'EOF'
Update only EFI/OpenDuet (plus ESP/Kernels when present) on an existing disk.

Usage:
  sudo ./scripts/linux_make_usb.sh --update-efi \
    --disk /dev/sdX \
    --build-root output/.../opencore-custom \
    [--esp-part /dev/sdX1] [--dry-run] [--allow-internal]
EOF
}

need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }
while (($#)); do
  case "$1" in
    --update-efi) ;;
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --esp-part) need_value "$@"; shift; ESP_PART="$1" ;;
    --build-root) need_value "$@"; shift; BUILD_ROOT="$1" ;;
    --allow-internal) ALLOW_INTERNAL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unsupported option for --update-efi: $1" ;;
  esac
  shift
done

[[ "$(uname -s)" == Linux ]] || die "Linux only"
[[ $EUID -eq 0 ]] || die "Run as root"
[[ -n "$DISK" ]] || die "--disk is required"
[[ -n "$BUILD_ROOT" ]] || die "--build-root is required"
[[ -b "$DISK" ]] || die "Not a block device: $DISK"
[[ "$(lsblk -dnro TYPE "$DISK" 2>/dev/null)" == disk ]] || die "Whole disk required: $DISK"

BUILD_ROOT="$(readlink -f "$BUILD_ROOT")"
[[ -f "$BUILD_ROOT/ESP/EFI/OC/config.plist" ]] || die "Missing $BUILD_ROOT/ESP/EFI/OC/config.plist"
[[ -f "$BUILD_ROOT/ESP/boot" ]] || die "Missing $BUILD_ROOT/ESP/boot"
[[ -d "$BUILD_ROOT/OpenDuet" ]] || die "Missing $BUILD_ROOT/OpenDuet"
[[ -x "$ROOT_DIR/scripts/linux_install_openduet.sh" || -f "$ROOT_DIR/scripts/linux_install_openduet.sh" ]] \
  || die "Missing scripts/linux_install_openduet.sh"

root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
root_parent=""
if [[ -n "$root_source" && -b "$root_source" ]]; then
  root_parent="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
  [[ -n "$root_parent" ]] && root_parent="/dev/$root_parent"
fi
[[ "$DISK" != "$root_source" && "$DISK" != "$root_parent" ]] || die "Refusing Linux root disk: $DISK"

rm_flag="$(lsblk -dnro RM "$DISK" 2>/dev/null | tr -d ' ')"
transport="$(lsblk -dnro TRAN "$DISK" 2>/dev/null | tr -d ' ')"
if [[ "$ALLOW_INTERNAL" -ne 1 && "$rm_flag" != 1 && "$transport" != usb ]]; then
  die "$DISK is not clearly removable/USB (RM=$rm_flag TRAN=${transport:-unknown}); use --allow-internal only after manual verification"
fi

partition_path() {
  local number="$1" candidate partno
  while IFS= read -r candidate; do
    [[ -n "$candidate" && -b "$candidate" ]] || continue
    partno="$(cat "/sys/class/block/$(basename "$candidate")/partition" 2>/dev/null || true)"
    [[ "$partno" == "$number" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done < <(lsblk -lnpo NAME,TYPE "$DISK" | awk '$2 == "part" {print $1}')
  return 1
}

have partprobe && partprobe "$DISK" >/dev/null 2>&1 || true
have udevadm && udevadm settle >/dev/null 2>&1 || true
[[ -n "$ESP_PART" ]] || ESP_PART="$(partition_path 1)"
[[ -n "$ESP_PART" && -b "$ESP_PART" ]] || die "Could not identify EFI partition; pass --esp-part"

fstype="$(blkid -s TYPE -o value "$ESP_PART" 2>/dev/null || true)"
case "$fstype" in vfat|fat|msdos) ;; *) die "EFI partition is not FAT: $ESP_PART ($fstype)" ;; esac

if (( DRY_RUN == 1 )); then
  if [[ -f "$BUILD_ROOT/ESP/Kernels/kernel" ]]; then
    printf 'DRY RUN: would replace EFI/OpenDuet + custom kernel on %s and reinstall robust legacy boot sectors on %s\n' "$ESP_PART" "$DISK"
  else
    printf 'DRY RUN: would replace EFI/OpenDuet on %s and reinstall robust legacy boot sectors on %s\n' "$ESP_PART" "$DISK"
  fi
  exit 0
fi

printf 'Type exactly: UPDATE EFI %s ON %s\n> ' "$ESP_PART" "$DISK"
IFS= read -r answer
[[ "$answer" == "UPDATE EFI $ESP_PART ON $DISK" ]] || die "Confirmation mismatch; nothing changed"

while IFS= read -r target; do
  [[ -n "$target" ]] || continue
  umount "$target" 2>/dev/null || true
done < <(lsblk -lnpo MOUNTPOINT "$DISK" | awk 'NF')

ESP_MOUNT="$(mktemp -d /tmp/legacy-efi-update.XXXXXX)"
mount -t vfat -o rw,noatime "$ESP_PART" "$ESP_MOUNT"

backup_dir="$ROOT_DIR/backup/linux-efi-$(date -u '+%Y%m%dT%H%M%SZ')-$(basename "$DISK")"
if [[ -d "$ESP_MOUNT/EFI" || -d "$ESP_MOUNT/Kernels" || -f "$ESP_MOUNT/boot" ]]; then
  mkdir -p "$backup_dir"
  [[ -d "$ESP_MOUNT/EFI" ]] && cp -a "$ESP_MOUNT/EFI" "$backup_dir/EFI"
  [[ -d "$ESP_MOUNT/Kernels" ]] && cp -a "$ESP_MOUNT/Kernels" "$backup_dir/Kernels"
  [[ -f "$ESP_MOUNT/boot" ]] && cp -a "$ESP_MOUNT/boot" "$backup_dir/boot"
  log "Backed up existing EFI/OpenDuet/kernel files to $backup_dir"
fi

rm -rf -- "$ESP_MOUNT/EFI" "$ESP_MOUNT/Kernels"
mkdir -p "$ESP_MOUNT/EFI"
cp -R --no-preserve=ownership,mode,timestamps "$BUILD_ROOT/ESP/EFI"/. "$ESP_MOUNT/EFI"/
if [[ -d "$BUILD_ROOT/ESP/Kernels" ]]; then
  mkdir -p "$ESP_MOUNT/Kernels"
  cp -R --no-preserve=ownership,mode,timestamps "$BUILD_ROOT/ESP/Kernels"/. "$ESP_MOUNT/Kernels"/
fi
cp --no-preserve=ownership,mode,timestamps "$BUILD_ROOT/ESP/boot" "$ESP_MOUNT/boot"
sync

[[ -f "$ESP_MOUNT/EFI/OC/config.plist" ]] || die "EFI copy failed: EFI/OC/config.plist missing"
[[ -f "$ESP_MOUNT/EFI/BOOT/BOOTIA32.efi" || -f "$ESP_MOUNT/EFI/BOOT/BOOTX64.efi" ]] || die "EFI copy failed: BOOT*.efi missing"
if [[ -f "$BUILD_ROOT/ESP/Kernels/kernel" ]]; then
  [[ -f "$ESP_MOUNT/Kernels/kernel" ]] || die "EFI copy failed: Kernels/kernel missing"
fi

umount "$ESP_MOUNT"
rmdir "$ESP_MOUNT"
ESP_MOUNT=""

log "Installing OpenDuet with robust non-interactive Linux helper"
bash "$ROOT_DIR/scripts/linux_install_openduet.sh" \
  --disk "$DISK" \
  --esp-part "$ESP_PART" \
  --build-root "$BUILD_ROOT"

ESP_MOUNT="$(mktemp -d /tmp/legacy-efi-verify.XXXXXX)"
mount -t vfat -o ro "$ESP_PART" "$ESP_MOUNT"
[[ -f "$ESP_MOUNT/EFI/OC/config.plist" ]] || die "Verification failed: EFI/OC/config.plist"
[[ -f "$ESP_MOUNT/boot" ]] || die "Verification failed: /boot"
if [[ -f "$BUILD_ROOT/ESP/Kernels/kernel" ]]; then
  [[ -f "$ESP_MOUNT/Kernels/kernel" ]] || die "Verification failed: Kernels/kernel"
  src_hash="$(sha256sum "$BUILD_ROOT/ESP/Kernels/kernel" | awk '{print $1}')"
  dst_hash="$(sha256sum "$ESP_MOUNT/Kernels/kernel" | awk '{print $1}')"
  [[ "$src_hash" == "$dst_hash" ]] || die "Verification failed: custom-kernel SHA256 mismatch"
  log "Custom kernel SHA256 verified: $dst_hash"
fi
umount "$ESP_MOUNT"
rmdir "$ESP_MOUNT"
ESP_MOUNT=""

log "EFI/OpenDuet update completed successfully"
