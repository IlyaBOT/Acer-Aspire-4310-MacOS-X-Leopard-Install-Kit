#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
KEXT_SOURCE="$ROOT_DIR/drivers/sdhci-o2micro/build/VoodooSDHC.kext"
EFI_MOUNT="/Volumes/EFI"
EFI_DEVICE=""
APPLY=0
REBOOT=0

usage() {
  cat <<'EOF'
Stage the diagnostic VoodooSDHC.kext for OpenCore injection.

Preview only (default):
  ./scripts/install-opencore-test.sh --kext PATH

Apply after explicitly reviewing the preview:
  ./scripts/install-opencore-test.sh --apply --kext PATH \
    --efi-mount /Volumes/EFI

Options:
  --kext PATH       built VoodooSDHC.kext
  --efi-mount PATH  already-mounted EFI volume (default: /Volumes/EFI)
  --efi-device DEV  mount this EFI partition with diskutil
  --apply           perform the backup/copy/config update
  --reboot          reboot after --apply (never implied)
  -h, --help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --kext)
      (($# > 1)) || die "--kext needs a value"
      KEXT_SOURCE="$2"; shift
      ;;
    --efi-mount)
      (($# > 1)) || die "--efi-mount needs a value"
      EFI_MOUNT="$2"; shift
      ;;
    --efi-device)
      (($# > 1)) || die "--efi-device needs a value"
      EFI_DEVICE="$2"; shift
      ;;
    --apply) APPLY=1 ;;
    --reboot) REBOOT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -d "$KEXT_SOURCE" ]] || die "kext bundle not found: $KEXT_SOURCE"
[[ -f "$KEXT_SOURCE/Contents/Info.plist" ]] || die "invalid kext bundle: $KEXT_SOURCE"

if (( REBOOT && !APPLY )); then
  die "--reboot requires --apply"
fi

if (( !APPLY )); then
  echo "Preview only; nothing will be changed."
  echo "  source: $KEXT_SOURCE"
  echo "  EFI:    $EFI_MOUNT"
  echo "  target: $EFI_MOUNT/EFI/OC/Kexts/VoodooSDHC.kext"
  echo "Run again with --apply to perform the change."
  exit 0
fi

if [[ -n "$EFI_DEVICE" ]]; then
  /usr/sbin/diskutil mount "$EFI_DEVICE" >/dev/null
  EFI_MOUNT="/Volumes/EFI"
fi

OC_DIR="$EFI_MOUNT/EFI/OC"
CONFIG="$OC_DIR/config.plist"
KEXT_DIR="$OC_DIR/Kexts"
TARGET="$KEXT_DIR/VoodooSDHC.kext"
[[ -d "$EFI_MOUNT" ]] || die "EFI mount not found: $EFI_MOUNT"
[[ -d "$OC_DIR" ]] || die "OpenCore directory not found: $OC_DIR"
[[ -f "$CONFIG" ]] || die "OpenCore config not found: $CONFIG"
[[ -d "$KEXT_DIR" ]] || die "OpenCore Kexts directory not found: $KEXT_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$OC_DIR/_diagnostic-backups/o2micro-$STAMP"
mkdir -p "$BACKUP"
cp -p "$CONFIG" "$BACKUP/config.plist"
if [[ -d "$TARGET" ]]; then
  mv "$TARGET" "$BACKUP/VoodooSDHC.kext.previous"
fi
ditto "$KEXT_SOURCE" "$TARGET"

/usr/bin/python - "$CONFIG" <<'PY'
from __future__ import with_statement
import os
import plistlib
import sys

config_path = sys.argv[1]
config = plistlib.readPlist(config_path)
kernel = config.setdefault("Kernel", {})
entries = kernel.setdefault("Add", [])
entry = {
    "Arch": "i386",
    "BundlePath": "VoodooSDHC.kext",
    "Comment": "O2Micro 1217:7120 diagnostic (PIO, read-only, timeout)",
    "Enabled": True,
    "ExecutablePath": "Contents/MacOS/VoodooSDHC",
    "MaxKernel": "10.8.0",
    "MinKernel": "10.0.0",
}
updated = []
replaced = False
for item in entries:
    if item.get("BundlePath") == entry["BundlePath"]:
        if not replaced:
            updated.append(entry)
            replaced = True
    else:
        updated.append(item)
if not replaced:
    updated.append(entry)
kernel["Add"] = updated

temporary = config_path + ".o2micro.tmp"
if os.path.exists(temporary):
    os.unlink(temporary)
plistlib.writePlist(config, temporary)
os.rename(temporary, config_path)
PY

/usr/bin/plutil -lint "$CONFIG"
sync
echo "Installed through OpenCore injection."
echo "Backup: $BACKUP"
echo "No reboot was performed."
if (( REBOOT )); then
  /sbin/shutdown -r now
fi
