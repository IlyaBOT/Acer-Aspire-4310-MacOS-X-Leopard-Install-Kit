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

if [[ ! -f /Volumes/EFI/EFI/OC/config.plist ]]; then
  sudo diskutil mount "$EFI_DEVICE" >/dev/null
fi

EFI=/Volumes/EFI/EFI/OC
CONFIG="$EFI/config.plist"
KEXTS="$EFI/Kexts"
PB=/usr/libexec/PlistBuddy
[[ -f "$CONFIG" ]] || die "OpenCore config not found"

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
cp -p "$CONFIG" "$HOME/Desktop/config.plist.before-cardreader-remove-$STAMP"

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
