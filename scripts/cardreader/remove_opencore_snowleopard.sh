#!/usr/bin/env bash
set -Eeuo pipefail

EFI_DEVICE="${EFI_DEVICE:-disk0s1}"
while (($#)); do
  case "$1" in
    --efi-device)
      shift
      [[ $# -gt 0 ]] || { echo "--efi-device needs a value" >&2; exit 2; }
      EFI_DEVICE="$1"
      ;;
    -h|--help)
      echo "Usage: $0 [--efi-device disk0s1]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '[cardreader-oc-remove] %s\n' "$*"; }
die() { printf '[cardreader-oc-remove] ERROR: %s\n' "$*" >&2; exit 1; }

disk_mount_point() {
  local dev="$1" mp
  mp="$(diskutil info "$dev" 2>/dev/null |
    sed -n 's/^[[:space:]]*Mount Point:[[:space:]]*//p' |
    head -1)"
  if [[ -z "$mp" || "$mp" == "Not mounted" ]]; then
    mp="$(mount | awk -v dev="/dev/$dev" '$1 == dev { print $3; exit }')"
  fi
  printf '%s\n' "$mp"
}

mount_is_writable() {
  local mp="$1" probe="$1/.cardreader-remove-write-test.$$"
  if sudo touch "$probe" 2>/dev/null; then
    sudo rm -f "$probe" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

mount_efi_rw() {
  local dev="$1" mp fallback
  fallback="/Volumes/CardReader-EFI-$dev"
  mp="$(disk_mount_point "$dev")"

  if [[ -n "$mp" && "$mp" != "Not mounted" ]]; then
    if mount_is_writable "$mp"; then
      printf '%s\n' "$mp"
      return 0
    fi
    log "EFI $dev is mounted read-only at '$mp'; remounting read-write" >&2
    sudo umount "$mp" >/dev/null 2>&1 ||
      sudo diskutil unmount "$dev" >/dev/null 2>&1 ||
      return 1
    mp=""
  fi

  log "mounting EFI from $dev with diskutil" >&2
  if sudo diskutil mount "$dev" >/dev/null 2>&1; then
    mp="$(disk_mount_point "$dev")"
  fi

  if [[ -z "$mp" || "$mp" == "Not mounted" ]]; then
    log "diskutil mount failed; falling back to mount_msdos for $dev" >&2
    sudo mkdir -p "$fallback"
    sudo /sbin/mount_msdos "/dev/$dev" "$fallback" || return 1
    mp="$fallback"
  fi

  mount_is_writable "$mp" || return 1
  printf '%s\n' "$mp"
}

MP="$(mount_efi_rw "$EFI_DEVICE")" || die "failed to mount $EFI_DEVICE read-write"
EFI="$MP/EFI/OC"
CONFIG="$EFI/config.plist"
KEXTS="$EFI/Kexts"
PB=/usr/libexec/PlistBuddy
[[ -f "$CONFIG" ]] || die "OpenCore config not found at $CONFIG"

COUNT="$($PB -c 'Print :Kernel:Add' "$CONFIG" 2>/dev/null | grep -c 'Dict {' || true)"
COUNT="$(printf '%s' "$COUNT" | tr -d '[:space:]')"
[[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0

INDEX=""
i=0
while [[ "$i" -lt "$COUNT" ]]; do
  BP="$($PB -c "Print :Kernel:Add:$i:BundlePath" "$CONFIG" 2>/dev/null || true)"
  if [[ "$BP" == "VoodooSDHC.kext" ]]; then
    INDEX="$i"
    break
  fi
  i=$((i + 1))
done

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/Desktop/config.plist.before-cardreader-remove-$STAMP"
cp -p "$CONFIG" "$BACKUP"
log "config backup: $BACKUP"

if [[ -n "$INDEX" ]]; then
  sudo "$PB" -c "Delete :Kernel:Add:$INDEX" "$CONFIG"
  log "removed Kernel->Add entry $INDEX"
else
  log "no VoodooSDHC Kernel->Add entry found"
fi

if [[ -d "$KEXTS/VoodooSDHC.kext" ]]; then
  sudo rm -rf "$KEXTS/VoodooSDHC.kext"
  log "removed EFI/OC/Kexts/VoodooSDHC.kext"
fi

plutil -lint "$CONFIG"
sync
log "OpenCore card-reader injection removed"
