#!/usr/bin/env bash
set -Eeuo pipefail

KEXT=""
EFI_DEVICE="${EFI_DEVICE:-}"
DISABLE_SLE=0
APPLY=0

usage() {
  cat <<'EOF'
Usage:
  install_opencore_snowleopard.sh /path/to/VoodooSDHC.kext [--efi-device disk0s1] [--disable-sle-conflicts]

The script validates the KEXT and previews the target paths by default. With
--apply it backs up OpenCore config.plist, installs VoodooSDHC.kext into the
OpenCore EFI, and adds/updates an i386 Kernel->Add entry limited to Darwin 10.x.

By default the installer auto-detects EFI partitions and selects the only one
containing EFI/OC/config.plist. If more than one OpenCore EFI is found, specify
the intended partition explicitly with --efi-device.

On Snow Leopard, diskutil may fail to mount a perfectly valid FAT EFI system
partition. In that case the installer falls back to mount_msdos. A read-only
manual EFI mount is automatically remounted read-write before applying changes.

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
    --apply) APPLY=1 ;;
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

disk_identifier_for_path() {
  diskutil info "$1" 2>/dev/null |
    sed -n 's/^[[:space:]]*Device Identifier:[[:space:]]*//p' |
    head -1
}

mount_is_writable() {
  local mp="$1" probe="$1/.cardreader-write-test.$$"
  if sudo touch "$probe" 2>/dev/null; then
    sudo rm -f "$probe" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

mount_efi_device() {
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

  if [[ -z "$mp" || "$mp" == "Not mounted" ]]; then
    log "mounting EFI from $dev with diskutil" >&2
    if sudo diskutil mount "$dev" >/dev/null 2>&1; then
      mp="$(disk_mount_point "$dev")"
    fi
  fi

  if [[ -z "$mp" || "$mp" == "Not mounted" ]]; then
    log "diskutil mount failed; falling back to mount_msdos for $dev" >&2
    sudo mkdir -p "$fallback"
    sudo /sbin/mount_msdos "/dev/$dev" "$fallback" || return 1
    mp="$fallback"
  fi

  [[ -n "$mp" && "$mp" != "Not mounted" ]] || return 1

  if ! mount_is_writable "$mp"; then
    log "EFI $dev is not writable at '$mp'" >&2
    return 1
  fi

  printf '%s\n' "$mp"
}

[[ -n "$KEXT" ]] || { usage >&2; exit 2; }
KEXT="$(cd "$(dirname "$KEXT")" && pwd -P)/$(basename "$KEXT")"
[[ -d "$KEXT" ]] || die "KEXT not found: $KEXT"
BIN="$KEXT/Contents/MacOS/VoodooSDHC"
INFO="$KEXT/Contents/Info.plist"
[[ -f "$BIN" && -f "$INFO" ]] || die "not a VoodooSDHC.kext bundle: $KEXT"
file "$BIN" | grep -q 'i386' || die "KEXT executable does not contain i386"
plutil -lint "$INFO" >/dev/null || die "invalid KEXT Info.plist"
MATCH="$(/usr/libexec/PlistBuddy -c 'Print :IOKitPersonalities:SD\ Card\ Host\ Controller:IOPCIMatch' "$INFO" 2>/dev/null || true)"
printf '%s\n' "$MATCH" | grep -q '0x71201217' || die "KEXT does not match O2Micro 1217:7120"

if [[ "$DISABLE_SLE" -eq 0 ]]; then
  if [[ -d /System/Library/Extensions/IOSDHCIBlockDevice.kext || -d /System/Library/Extensions/VoodooSDHC.kext ]]; then
    die "conflicting card-reader KEXT exists in /System/Library/Extensions; re-run with --disable-sle-conflicts"
  fi
fi

if [[ "$APPLY" -eq 0 ]]; then
  echo "Preview only; nothing will be changed."
  echo "  source: $KEXT"
  if [[ -n "$EFI_DEVICE" ]]; then
    echo "  EFI device: $EFI_DEVICE"
  else
    echo "  EFI device: auto-detect OpenCore EFI"
  fi
  echo "  target: <OpenCore EFI>/EFI/OC/Kexts/VoodooSDHC.kext"
  echo "  config: <OpenCore EFI>/EFI/OC/config.plist"
  echo "Run again with --apply to perform the change."
  exit 0
fi

EFI_ROOT=""
RESOLVED_DEVICE=""

if [[ -n "$EFI_DEVICE" ]]; then
  MP="$(mount_efi_device "$EFI_DEVICE")" || die "failed to mount EFI device $EFI_DEVICE"
  [[ -f "$MP/EFI/OC/config.plist" ]] ||
    die "$EFI_DEVICE mounted at '$MP' but EFI/OC/config.plist was not found there"
  EFI_ROOT="$MP/EFI/OC"
  RESOLVED_DEVICE="$EFI_DEVICE"
else
  MATCH_ROOTS=()
  MATCH_DEVS=()

  add_match() {
    local root="$1" dev="$2" existing
    for existing in "${MATCH_ROOTS[@]}"; do
      [[ "$existing" == "$root" ]] && return 0
    done
    MATCH_ROOTS[${#MATCH_ROOTS[@]}]="$root"
    MATCH_DEVS[${#MATCH_DEVS[@]}]="$dev"
  }

  # Check already mounted volumes first without assuming the mount name is
  # literally /Volumes/EFI; macOS may use "EFI 1", "EFI 2", etc. Read-only
  # matches are discovered here and remounted read-write below when selected.
  for VOL in /Volumes/*; do
    [[ -d "$VOL" ]] || continue
    if [[ -f "$VOL/EFI/OC/config.plist" ]]; then
      DEV="$(disk_identifier_for_path "$VOL")"
      if [[ -z "$DEV" ]]; then
        DEV="$(mount | awk -v mp="$VOL" '$3 == mp { sub("/dev/", "", $1); print $1; exit }')"
      fi
      add_match "$VOL/EFI/OC" "${DEV:-mounted-volume}"
    fi
  done

  # Mount each partition whose GPT/MBR listing identifies it as EFI and look
  # specifically for an OpenCore config. This avoids hard-coding disk0s1.
  EFI_CANDIDATES="$(diskutil list | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "EFI") {
        print $NF
        break
      }
    }
  }')"

  for DEV in $EFI_CANDIDATES; do
    case "$DEV" in
      disk*s*) ;;
      *) continue ;;
    esac
    MP="$(disk_mount_point "$DEV")"
    if [[ -z "$MP" || "$MP" == "Not mounted" ]]; then
      MP="$(mount_efi_device "$DEV" 2>/dev/null || true)"
    fi
    [[ -n "$MP" ]] || continue
    if [[ -f "$MP/EFI/OC/config.plist" ]]; then
      add_match "$MP/EFI/OC" "$DEV"
    fi
  done

  if [[ "${#MATCH_ROOTS[@]}" -eq 0 ]]; then
    printf '[cardreader-oc] No EFI partition containing EFI/OC/config.plist was found.\n' >&2
    printf '[cardreader-oc] diskutil list follows:\n' >&2
    diskutil list >&2 || true
    die "specify the correct partition with --efi-device diskXsY if OpenCore is on a non-standard partition"
  fi

  if [[ "${#MATCH_ROOTS[@]}" -gt 1 ]]; then
    printf '[cardreader-oc] Multiple OpenCore EFI partitions were found:\n' >&2
    i=0
    while [[ "$i" -lt "${#MATCH_ROOTS[@]}" ]]; do
      printf '  %s -> %s\n' "${MATCH_DEVS[$i]}" "${MATCH_ROOTS[$i]}" >&2
      i=$((i + 1))
    done
    die "re-run with --efi-device <partition> to select the EFI used to boot this machine"
  fi

  RESOLVED_DEVICE="${MATCH_DEVS[0]}"
  case "$RESOLVED_DEVICE" in
    disk*s*)
      MP="$(mount_efi_device "$RESOLVED_DEVICE")" || die "failed to mount EFI device $RESOLVED_DEVICE read-write"
      [[ -f "$MP/EFI/OC/config.plist" ]] || die "OpenCore config disappeared after remounting $RESOLVED_DEVICE"
      EFI_ROOT="$MP/EFI/OC"
      ;;
    *)
      EFI_ROOT="${MATCH_ROOTS[0]}"
      ;;
  esac
fi

EFI="$EFI_ROOT"
CONFIG="$EFI/config.plist"
KEXTS="$EFI/Kexts"
[[ -f "$CONFIG" ]] || die "OpenCore config not found: $CONFIG"
[[ -d "$KEXTS" ]] || die "OpenCore Kexts directory not found: $KEXTS"
log "OpenCore EFI: $RESOLVED_DEVICE -> $EFI"

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
sudo rm -rf "$KEXTS/VoodooSDHC.kext"
sudo cp -R "$KEXT" "$KEXTS/VoodooSDHC.kext"

PB=/usr/libexec/PlistBuddy
# Count dictionaries in Kernel->Add. PlistBuddy's array print format uses one
# 'Dict {' line per element on Snow Leopard. grep exits 1 for zero matches, so
# protect the pipeline under set -o pipefail.
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

if [[ -z "$INDEX" ]]; then
  INDEX="$COUNT"
  sudo "$PB" -c "Add :Kernel:Add:$INDEX dict" "$CONFIG"
  log "created Kernel->Add entry $INDEX"
else
  log "updating existing Kernel->Add entry $INDEX"
fi

set_field() {
  # Bash 3.2 expands a compound `local a=... b=... c=$a` command before the
  # assignments take effect. Under `set -u`, referencing $key in that same
  # declaration therefore aborts with "unbound variable". Assign in separate
  # statements so this remains Snow Leopard/Bash-3.2 safe.
  local key type value path
  key="$1"
  type="$2"
  value="$3"
  path=":Kernel:Add:$INDEX:$key"

  if "$PB" -c "Print $path" "$CONFIG" >/dev/null 2>&1; then
    sudo "$PB" -c "Set $path $value" "$CONFIG"
  else
    sudo "$PB" -c "Add $path $type $value" "$CONFIG"
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
