#!/usr/bin/env bash
set -Eeuo pipefail

KEXT=""
EFI_DEVICE="${EFI_DEVICE:-disk0s1}"
DISABLE_SLE=0

usage() {
  cat <<'EOF'
Usage:
  install_opencore_snowleopard.sh /path/to/VoodooSDHC.kext [--efi-device disk0s1] [--disable-sle-conflicts]

The script backs up OpenCore config.plist, installs VoodooSDHC.kext into
EFI/OC/Kexts, and adds/updates an i386 Kernel->Add entry limited to Darwin 10.x.

--disable-sle-conflicts moves IOSDHCIBlockDevice.kext/VoodooSDHC.kext out of
/System/Library/Extensions and rebuilds Snow Leopard's kernel caches. Use this
when migrating the current S/L/E test driver to OpenCore injection.
EOF
}

while (($#)); do
  case "$1" in
    --efi-device)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 2; }
      EFI_DEVICE="$1"
      ;;
    --disable-sle-conflicts) DISABLE_SLE=1 ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      [[ -z "$KEXT" ]] || { echo "Only one KEXT path may be supplied" >&2; exit 2; }
      KEXT="$1"
      ;;
  esac
  shift
done

log() { printf '[cardreader-oc] %s\n' "$*"; }
die() { printf '[cardreader-oc] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -n "$KEXT" ]] || { usage >&2; exit 2; }
KEXT="$(cd "$(dirname "$KEXT")" && pwd -P)/$(basename "$KEXT")"
[[ -d "$KEXT" ]] || die "KEXT not found: $KEXT"
BIN="$KEXT/Contents/MacOS/VoodooSDHC"
INFO="$KEXT/Contents/Info.plist"
[[ -f "$BIN" && -f "$INFO" ]] || die "not a VoodooSDHC.kext bundle: $KEXT"
file "$BIN" | grep -q 'i386' || die "KEXT executable does not contain i386"
plutil -lint "$INFO" >/dev/null || die "invalid KEXT Info.plist"
MATCH="$(/usr/libexec/PlistBuddy -c 'Print :IOKitPersonalities:SD Card Host Controller:IOPCIMatch' "$INFO" 2>/dev/null || true)"
printf '%s\n' "$MATCH" | grep -q '0x71201217' || die "KEXT does not match O2Micro 1217:7120"

if [[ "$DISABLE_SLE" -eq 0 ]]; then
  if [[ -d /System/Library/Extensions/IOSDHCIBlockDevice.kext || -d /System/Library/Extensions/VoodooSDHC.kext ]]; then
    die "conflicting card-reader KEXT exists in /System/Library/Extensions; re-run with --disable-sle-conflicts"
  fi
fi

if [[ ! -f /Volumes/EFI/EFI/OC/config.plist ]]; then
  log "mounting EFI from $EFI_DEVICE"
  sudo diskutil mount "$EFI_DEVICE" >/dev/null
fi

EFI=/Volumes/EFI/EFI/OC
CONFIG="$EFI/config.plist"
KEXTS="$EFI/Kexts"
[[ -f "$CONFIG" ]] || die "OpenCore config not found: $CONFIG"
[[ -d "$KEXTS" ]] || die "OpenCore Kexts directory not found: $KEXTS"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/Desktop/cardreader-opencore-backup-$STAMP"
mkdir -p "$BACKUP"
cp -p "$CONFIG" "$BACKUP/config.plist"
if [[ -d "$KEXTS/VoodooSDHC.kext" ]]; then
  cp -R "$KEXTS/VoodooSDHC.kext" "$BACKUP/VoodooSDHC.kext.previous"
fi
log "backup: $BACKUP"

if [[ "$DISABLE_SLE" -eq 1 ]]; then
  SLE_BACKUP="$BACKUP/SLE"
  mkdir -p "$SLE_BACKUP"
  CHANGED_SLE=0
  for OLD in IOSDHCIBlockDevice.kext VoodooSDHC.kext; do
    if [[ -d "/System/Library/Extensions/$OLD" ]]; then
      log "moving S/L/E conflict: $OLD"
      sudo mv "/System/Library/Extensions/$OLD" "$SLE_BACKUP/$OLD"
      CHANGED_SLE=1
    fi
  done
  if [[ "$CHANGED_SLE" -eq 1 ]]; then
    sudo touch /System/Library/Extensions
    sudo kextcache -system-prelinked-kernel
    sudo kextcache -system-caches
  fi
fi

log "installing KEXT into OpenCore"
rm -rf "$KEXTS/VoodooSDHC.kext"
cp -R "$KEXT" "$KEXTS/VoodooSDHC.kext"

PB=/usr/libexec/PlistBuddy
# Count dictionaries in Kernel->Add. PlistBuddy's array print format uses one
# 'Dict {' line per element on Snow Leopard.
COUNT="$($PB -c 'Print :Kernel:Add' "$CONFIG" | grep -c 'Dict {' | tr -d ' ')"
[[ -n "$COUNT" ]] || COUNT=0
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

if [[ -z "$INDEX" ]]; then
  INDEX="$COUNT"
  $PB -c "Add :Kernel:Add:$INDEX dict" "$CONFIG"
  log "created Kernel->Add entry $INDEX"
else
  log "updating existing Kernel->Add entry $INDEX"
fi

set_field() {
  local key="$1" type="$2" value="$3" path=":Kernel:Add:$INDEX:$key"
  if $PB -c "Print $path" "$CONFIG" >/dev/null 2>&1; then
    $PB -c "Set $path $value" "$CONFIG"
  else
    $PB -c "Add $path $type $value" "$CONFIG"
  fi
}

set_field Arch string i386
set_field BundlePath string VoodooSDHC.kext
set_field Comment string 'O2Micro-1217-7120-diagnostic'
set_field Enabled bool true
set_field ExecutablePath string Contents/MacOS/VoodooSDHC
set_field MinKernel string 10.0.0
set_field MaxKernel string 10.99.99
set_field PlistPath string Contents/Info.plist

plutil -lint "$CONFIG"
sync

log "installed OpenCore KEXT entry for Darwin 10.x / i386"
log "IMPORTANT: remove the SD card before rebooting the first diagnostic build"
log "backup for rollback: $BACKUP"
log "reboot only after you have an SSH path back into the machine"
