#!/usr/bin/env bash
# Destructive Linux writer for OpenCore online-Recovery media.
# Creates one GPT EFI System Partition (FAT32), copies the prepared UEFI tree,
# and downloads Mavericks Recovery directly onto the USB with macrecovery.py.
set -Eeuo pipefail

MODE=""
DISK=""
BUILD_ROOT=""
MACRECOVERY=""
ASSUME_YES=0
ALLOW_INTERNAL=0
LABEL="MAC"
MNT=""

# OpenCore macrecovery identifiers for Mavericks.
MAVERICKS_BOARD_ID="Mac-F60DEB81FF30ACF6"
MAVERICKS_MLB="00000000000FNN100"

log() { printf '[recovery-usb] %s\n' "$*"; }
die() { printf '[recovery-usb] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }

usage() {
  cat <<'EOF'
Create a fresh UEFI OpenCore Mavericks Recovery USB on Linux.

DESTRUCTIVE:
  sudo ./scripts/linux_make_recovery_usb.sh --make-usb \
    --disk /dev/sdX \
    --build-root output/targets/asrock-fm2a58m-vg3-a8-7600/mavericks/opencore-custom \
    --macrecovery cache/carnations-opencore/.../Utilities/macrecovery/macrecovery.py

Options:
  --yes             skip the destructive confirmation prompt
  --allow-internal  permit a disk whose RM flag is not 1
  --label NAME      FAT32 label, default MAC
EOF
}

cleanup() {
  set +e
  if [[ -n "$MNT" && -d "$MNT" ]] && mountpoint -q "$MNT"; then
    umount "$MNT"
  fi
  [[ -n "$MNT" && -d "$MNT" ]] && rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

while (($#)); do
  case "$1" in
    --make-usb) MODE="make-usb" ;;
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --build-root) need_value "$@"; shift; BUILD_ROOT="$1" ;;
    --macrecovery) need_value "$@"; shift; MACRECOVERY="$1" ;;
    --label) need_value "$@"; shift; LABEL="$1" ;;
    --yes) ASSUME_YES=1 ;;
    --allow-internal) ALLOW_INTERNAL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ "$MODE" == "make-usb" ]] || { usage; exit 2; }
[[ "$(uname -s)" == "Linux" ]] || die "Linux only"
[[ $EUID -eq 0 ]] || die "Run this command with sudo/root"
[[ -n "$DISK" ]] || die "--disk is required"
[[ -n "$BUILD_ROOT" ]] || die "--build-root is required"
[[ -n "$MACRECOVERY" ]] || die "--macrecovery is required"

DISK="$(readlink -f "$DISK")"
BUILD_ROOT="$(readlink -f "$BUILD_ROOT")"
MACRECOVERY="$(readlink -f "$MACRECOVERY")"

[[ -b "$DISK" ]] || die "Not a block device: $DISK"
[[ "$(lsblk -ndo TYPE "$DISK" | head -n1)" == "disk" ]] || die "Target must be a whole disk: $DISK"

for cmd in lsblk findmnt blkid wipefs mkfs.vfat mount umount mountpoint python3 blockdev; do
  have "$cmd" || die "Missing required command: $cmd"
done
if ! have sgdisk && ! have parted; then
  die "Need either sgdisk (gdisk package) or parted"
fi

RM="$(lsblk -ndo RM "$DISK" | head -n1 | tr -d ' ')"
if [[ "$RM" != "1" && $ALLOW_INTERNAL -ne 1 ]]; then
  die "$DISK is not marked removable (RM=$RM). Re-run with --allow-internal only if this is definitely the target."
fi

[[ -f "$BUILD_ROOT/ESP/EFI/BOOT/BOOTX64.efi" ]] || die "Missing BOOTX64.efi in build"
[[ -f "$BUILD_ROOT/ESP/EFI/OC/OpenCore.efi" ]] || die "Missing OpenCore.efi in build"
[[ -f "$BUILD_ROOT/ESP/EFI/OC/config.plist" ]] || die "Missing config.plist in build"
[[ -f "$BUILD_ROOT/ESP/EFI/OC/Drivers/OpenHfsPlus.efi" ]] || die "Missing OpenHfsPlus.efi in build"
[[ ! -e "$BUILD_ROOT/ESP/EFI/OC/Drivers/HfsPlusLegacy.efi" ]] || die "Build still contains HfsPlusLegacy.efi"
[[ -f "$BUILD_ROOT/ESP/Kernels/mach_kernel" ]] || die "Missing ESP/Kernels/mach_kernel in build"
[[ -f "$MACRECOVERY" ]] || die "macrecovery.py not found: $MACRECOVERY"

python3 - "$BUILD_ROOT/ESP/EFI/OC/config.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    c=plistlib.load(f)
drivers=[]
for d in c["UEFI"]["Drivers"]:
    if isinstance(d, dict):
        if d.get("Enabled", True):
            drivers.append(d.get("Path"))
    else:
        drivers.append(d)
assert "OpenHfsPlus.efi" in drivers
assert "HfsPlusLegacy.efi" not in drivers
assert "OpenRuntime.efi" in drivers
s=c["Kernel"]["Scheme"]
assert s["CustomKernel"] is True
assert s["KernelArch"] == "x86_64"
assert s["KernelCache"] == "Cacheless"
q=c["Booter"]["Quirks"]
assert q["EnableWriteUnprotector"] is False
assert q["RebuildAppleMemoryMap"] is True
assert q["SyncRuntimePermissions"] is True
print("UEFI config preflight: PASS")
PY

printf '\nTARGET DISK (WILL BE ERASED):\n'
lsblk -o NAME,PATH,SIZE,MODEL,TRAN,RM,RO,FSTYPE,LABEL,MOUNTPOINTS "$DISK"
printf '\nThis creates a fresh GPT + one FAT32 EFI System Partition and downloads Mavericks Recovery.\n'

if (( ASSUME_YES == 0 )); then
  read -r -p "Type exactly ERASE $DISK: " ANSWER </dev/tty
  [[ "$ANSWER" == "ERASE $DISK" ]] || die "Cancelled"
fi

log "Unmounting existing partitions"
while IFS= read -r node; do
  [[ "$node" == "$DISK" ]] && continue
  if findmnt -rn -S "$node" >/dev/null 2>&1; then
    # Unmount by block-device path rather than the rendered mountpoint. findmnt
    # escapes spaces as \\x20 by default, which is not a valid path for umount.
    umount "$node" || die "Failed to unmount $node"
  fi
done < <(lsblk -lnpo NAME "$DISK")

# Refuse to wipe a disk while any child filesystem is still mounted.
while IFS= read -r node; do
  [[ "$node" == "$DISK" ]] && continue
  if findmnt -rn -S "$node" >/dev/null 2>&1; then
    mp="$(findmnt -rn --raw -S "$node" -o TARGET 2>/dev/null | head -n1 || true)"
    if [[ -n "$mp" ]]; then
      die "$node is still mounted at $mp"
    else
      die "$node is still mounted"
    fi
  fi
done < <(lsblk -lnpo NAME "$DISK")

log "Erasing partition metadata"
wipefs -a "$DISK" >/dev/null

if have sgdisk; then
  sgdisk --zap-all "$DISK" >/dev/null
  sgdisk -n 1:2048:0 -t 1:EF00 -c 1:"$LABEL" "$DISK" >/dev/null
else
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart ESP fat32 1MiB 100%
  parted -s "$DISK" set 1 esp on
  parted -s "$DISK" name 1 "$LABEL"
fi

have partprobe && partprobe "$DISK" || true
have udevadm && udevadm settle || true
sleep 1

case "$DISK" in
  *[0-9]) ESP="${DISK}p1" ;;
  *) ESP="${DISK}1" ;;
esac
[[ -b "$ESP" ]] || die "Partition did not appear: $ESP"

log "Formatting $ESP as FAT32 EFI System Partition"
mkfs.vfat -F 32 -n "$LABEL" "$ESP" >/dev/null

MNT="$(mktemp -d /tmp/mavericks-recovery-usb.XXXXXX)"
mount -t vfat -o rw,noatime "$ESP" "$MNT"

log "Copying UEFI OpenCore tree"
mkdir -p "$MNT/EFI" "$MNT/Kernels"
cp -R --no-preserve=ownership,mode,timestamps "$BUILD_ROOT/ESP/EFI/." "$MNT/EFI/"
cp --no-preserve=ownership,mode,timestamps "$BUILD_ROOT/ESP/Kernels/mach_kernel" "$MNT/Kernels/mach_kernel"

log "Downloading Mavericks Recovery with macrecovery.py"
mkdir -p "$MNT/com.apple.recovery.boot"
python3 "$MACRECOVERY" download \
  -b "$MAVERICKS_BOARD_ID" \
  -m "$MAVERICKS_MLB" \
  -o "$MNT/com.apple.recovery.boot" \
  -n RecoveryImage

[[ -s "$MNT/com.apple.recovery.boot/RecoveryImage.dmg" ]] || die "RecoveryImage.dmg was not downloaded"
[[ -s "$MNT/com.apple.recovery.boot/RecoveryImage.chunklist" ]] || die "RecoveryImage.chunklist was not downloaded"
[[ -f "$MNT/EFI/BOOT/BOOTX64.efi" ]] || die "BOOTX64.efi missing after copy"
[[ -f "$MNT/EFI/OC/Drivers/OpenHfsPlus.efi" ]] || die "OpenHfsPlus.efi missing after copy"
[[ -f "$MNT/Kernels/mach_kernel" ]] || die "mach_kernel missing after copy"

sync
blockdev --flushbufs "$DISK" || true

printf '\nFinal USB layout:\n'
ls -lh "$MNT/EFI/BOOT/BOOTX64.efi" \
       "$MNT/EFI/OC/OpenCore.efi" \
       "$MNT/EFI/OC/Drivers/OpenHfsPlus.efi" \
       "$MNT/Kernels/mach_kernel" \
       "$MNT/com.apple.recovery.boot/RecoveryImage.dmg" \
       "$MNT/com.apple.recovery.boot/RecoveryImage.chunklist"

umount "$MNT"
rmdir "$MNT"
MNT=""

log "DONE: UEFI Mavericks Recovery USB is ready on $DISK"
log "Boot it from the motherboard's UEFI: <USB name> entry, not the legacy/CSM entry."
