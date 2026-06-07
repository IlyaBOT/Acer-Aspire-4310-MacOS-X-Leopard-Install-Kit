#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$SCRIPT_DIR"
DOWNLOADS_DIR="$ROOT_DIR/downloads"
INPUT_DIR="$ROOT_DIR/input"
WORK_DIR="$ROOT_DIR/work"
LOGS_DIR="$ROOT_DIR/logs"
OUTPUT_DIR="$ROOT_DIR/output"

APPLE_1058_PAGE="https://support.apple.com/en-us/106460"
APPLE_1058_FALLBACK_URL="https://updates.cdn-apple.com/2019/cert/041-85213-20191017-1c7ca848-489c-4562-9a6a-2cfe4e04ccb0/MacOSXUpdCombo10.5.8.dmg"
APPLE_1058_DMG="$DOWNLOADS_DIR/MacOSXUpdCombo10.5.8.dmg"

APPLE_1056_PAGE="${APPLE_1056_PAGE:-https://support.apple.com/downloads/Mac_OS_X_10_5_6_Combo_Update}"
APPLE_1056_DMG_URL="${APPLE_1056_DMG_URL:-}"
APPLE_1056_DMG="$DOWNLOADS_DIR/MacOSXUpdCombo10.5.6.dmg"

LEGACY_KEXTS_URL="https://github.com/khronokernel/Legacy-Kexts/archive/refs/heads/master.zip"
LEGACY_ZIP="$DOWNLOADS_DIR/Legacy-Kexts-master.zip"
LEGACY_WORK_DIR="$WORK_DIR/Legacy-Kexts"

CHAMELEON_URL="http://chameleon.osx86.hu/file_download/45/Chameleon-2.2svn-r2404-binaries.tar.gz"
CHAMELEON_DOWNLOAD="$DOWNLOADS_DIR/Chameleon-2.2svn-r2404-binaries.tar.gz"
CHAMELEON_MANUAL_ARCHIVE="$DOWNLOADS_DIR/chameleon-binaries.tar.gz"
CHAMELEON_WORK_DIR="$WORK_DIR/chameleon"

MODE=""
DISK=""
RETAIL=""
TARGET=""
SLICE=""
EXECUTE_HDD=0
ATTACHED_IMAGE_DEVICE=""

usage() {
  cat <<'EOF'
Usage:
  ./prepare_acer4310_leopard_usb.sh --download-only
  ./prepare_acer4310_leopard_usb.sh --list-disks
  ./prepare_acer4310_leopard_usb.sh --make-usb --disk /dev/diskX --retail /path/to/Leopard.dmg
  ./prepare_acer4310_leopard_usb.sh --make-usb --disk /dev/diskX --retail /path/to/Leopard.iso
  ./prepare_acer4310_leopard_usb.sh --make-usb --disk /dev/diskX --retail "/Volumes/Mac OS X Install DVD"
  ./prepare_acer4310_leopard_usb.sh --install-chameleon-hdd --target /Volumes/LeopardHD --disk /dev/disk0 --slice /dev/disk0s2

Notes:
  - USB/HDD installation modes require macOS tools: diskutil, hdiutil, asr, fdisk, dd.
  - The retail Leopard installer is not downloaded. Supply a legally obtained DVD/image with --retail.
  - Destructive USB preparation requires typing exactly: ERASE /dev/diskX
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_macos() {
  [[ "$(uname -s 2>/dev/null || printf unknown)" == "Darwin" ]]
}

require_macos() {
  is_macos || die "This mode requires macOS. Run --download-only on Windows/Linux, then use --make-usb on a Mac."
}

require_cmd() {
  have_cmd "$1" || die "Required command not found: $1"
}

ensure_dirs() {
  mkdir -p "$DOWNLOADS_DIR" "$INPUT_DIR" "$WORK_DIR" "$LOGS_DIR" "$OUTPUT_DIR"
  if [[ ! -f "$INPUT_DIR/PUT_RETAIL_LEOPARD_IMAGE_HERE.txt" ]]; then
    cat >"$INPUT_DIR/PUT_RETAIL_LEOPARD_IMAGE_HERE.txt" <<'EOF'
Place your legally obtained Mac OS X Leopard retail DVD image here if you want.
The script will also accept any existing path passed with --retail.

Do not use unofficial or pirated Leopard images.
EOF
  fi
}

cleanup() {
  if [[ -n "${ATTACHED_IMAGE_DEVICE:-}" ]] && is_macos; then
    hdiutil detach "$ATTACHED_IMAGE_DEVICE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

safe_rm_rf() {
  local path="$1"
  case "$path" in
    "$WORK_DIR"/*|"$OUTPUT_DIR"/*)
      rm -rf -- "$path"
      ;;
    *)
      die "Refusing to remove path outside kit work/output directory: $path"
      ;;
  esac
}

download_url() {
  local url="$1"
  local dest="$2"
  local label="$3"
  local tmp

  if [[ -s "$dest" ]]; then
    log "Using existing $label: $dest"
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  tmp="${dest}.part"
  rm -f -- "$tmp"

  log "Downloading $label"
  log "URL: $url"
  if have_cmd curl; then
    if ! curl -fsSL --retry 3 --connect-timeout 20 --output "$tmp" "$url"; then
      rm -f -- "$tmp"
      return 1
    fi
  elif have_cmd wget; then
    if ! wget -O "$tmp" "$url"; then
      rm -f -- "$tmp"
      return 1
    fi
  elif have_cmd python3; then
    if ! python3 - "$url" "$tmp" <<'PY'
import shutil
import sys
import urllib.request

url, dest = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=60) as response, open(dest, "wb") as fh:
    shutil.copyfileobj(response, fh)
PY
    then
      rm -f -- "$tmp"
      return 1
    fi
  else
    die "Need curl, wget, or python3 to download files."
  fi

  if [[ ! -s "$tmp" ]]; then
    rm -f -- "$tmp"
    warn "Downloaded file is empty for $label"
    return 1
  fi
  mv -f -- "$tmp" "$dest"
}

fetch_url_to_file() {
  local url="$1"
  local dest="$2"

  mkdir -p "$(dirname "$dest")"
  rm -f -- "$dest"
  if have_cmd curl; then
    curl -fsSL --connect-timeout 20 --output "$dest" "$url"
  elif have_cmd wget; then
    wget -q -O "$dest" "$url"
  elif have_cmd python3; then
    python3 - "$url" "$dest" <<'PY'
import shutil
import sys
import urllib.request

url, dest = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=60) as response, open(dest, "wb") as fh:
    shutil.copyfileobj(response, fh)
PY
  else
    return 1
  fi
}

extract_first_apple_dmg_url() {
  local html="$1"
  grep -Eo 'https://updates\.cdn-apple\.com[^"<>[:space:]]+\.dmg' "$html" \
    | sed 's/&amp;/\&/g' \
    | head -n 1
}

download_apple_1058_combo() {
  local html="$WORK_DIR/apple-1058-combo.html"
  local dmg_url=""

  if fetch_url_to_file "$APPLE_1058_PAGE" "$html"; then
    dmg_url="$(extract_first_apple_dmg_url "$html" || true)"
  fi

  if [[ -z "$dmg_url" ]]; then
    warn "Could not parse Apple 10.5.8 page; using known Apple CDN fallback."
    dmg_url="$APPLE_1058_FALLBACK_URL"
  fi

  download_url "$dmg_url" "$APPLE_1058_DMG" "Mac OS X 10.5.8 Combo Update"
}

download_apple_1056_combo_optional() {
  local html="$WORK_DIR/apple-1056-combo.html"
  local dmg_url="$APPLE_1056_DMG_URL"

  if [[ -s "$APPLE_1056_DMG" ]]; then
    log "Using existing optional Mac OS X 10.5.6 Combo Update: $APPLE_1056_DMG"
    return 0
  fi

  if [[ -z "$dmg_url" ]] && fetch_url_to_file "$APPLE_1056_PAGE" "$html"; then
    dmg_url="$(extract_first_apple_dmg_url "$html" || true)"
  fi

  if [[ -z "$dmg_url" ]]; then
    warn "Apple no longer exposes a 10.5.6 Combo Update DMG at the known support URL."
    warn "Optional: place MacOSXUpdCombo10.5.6.dmg in downloads/ or set APPLE_1056_DMG_URL to an official Apple CDN URL."
    return 0
  fi

  download_url "$dmg_url" "$APPLE_1056_DMG" "Mac OS X 10.5.6 Combo Update"
}

extract_zip() {
  local zip="$1"
  local dest="$2"

  mkdir -p "$dest"
  if have_cmd unzip; then
    unzip -q "$zip" -d "$dest"
  elif have_cmd python3; then
    python3 - "$zip" "$dest" <<'PY'
import sys
import zipfile

zip_path, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path) as archive:
    archive.extractall(dest)
PY
  else
    die "Need unzip or python3 to extract $zip"
  fi
}

extract_targz() {
  local archive="$1"
  local dest="$2"

  mkdir -p "$dest"
  if have_cmd tar; then
    tar -xzf "$archive" -C "$dest"
  elif have_cmd python3; then
    python3 - "$archive" "$dest" <<'PY'
import sys
import tarfile

archive_path, dest = sys.argv[1], sys.argv[2]
with tarfile.open(archive_path, "r:gz") as archive:
    archive.extractall(dest)
PY
  else
    die "Need tar or python3 to extract $archive"
  fi
}

download_legacy_kexts() {
  download_url "$LEGACY_KEXTS_URL" "$LEGACY_ZIP" "Legacy-Kexts"
}

extract_legacy_kexts() {
  local temp="$WORK_DIR/.legacy-extract"
  local top=""

  [[ -s "$LEGACY_ZIP" ]] || die "Missing $LEGACY_ZIP. Run --download-only first."
  if [[ -d "$LEGACY_WORK_DIR/FAT" && -d "$LEGACY_WORK_DIR/Injectors" ]]; then
    log "Using existing extracted Legacy-Kexts: $LEGACY_WORK_DIR"
    return 0
  fi

  safe_rm_rf "$temp"
  safe_rm_rf "$LEGACY_WORK_DIR"
  extract_zip "$LEGACY_ZIP" "$temp"

  top="$(find "$temp" -maxdepth 1 -type d -name 'Legacy-Kexts*' -print -quit 2>/dev/null || true)"
  if [[ -z "$top" ]]; then
    die "Could not find Legacy-Kexts top-level directory after extraction."
  fi

  mv -- "$top" "$LEGACY_WORK_DIR"
  safe_rm_rf "$temp"
  log "Extracted Legacy-Kexts to $LEGACY_WORK_DIR"
}

chameleon_archive_to_use() {
  if [[ -s "$CHAMELEON_MANUAL_ARCHIVE" ]]; then
    printf '%s\n' "$CHAMELEON_MANUAL_ARCHIVE"
  elif [[ -s "$CHAMELEON_DOWNLOAD" ]]; then
    printf '%s\n' "$CHAMELEON_DOWNLOAD"
  fi
}

download_chameleon() {
  if [[ -s "$CHAMELEON_DOWNLOAD" || -s "$CHAMELEON_MANUAL_ARCHIVE" ]]; then
    log "Using existing Chameleon archive."
    return 0
  fi

  if download_url "$CHAMELEON_URL" "$CHAMELEON_DOWNLOAD" "Chameleon 2.2 r2404 binaries"; then
    return 0
  fi

  warn "Could not download Chameleon from $CHAMELEON_URL"
  warn "Place an archive containing i386/boot0, i386/boot1h, and i386/boot at:"
  warn "  $CHAMELEON_MANUAL_ARCHIVE"
  rm -f -- "${CHAMELEON_DOWNLOAD}.part"
}

extract_chameleon() {
  local archive
  local temp="$WORK_DIR/.chameleon-extract"

  archive="$(chameleon_archive_to_use || true)"
  if [[ -z "$archive" ]]; then
    warn "Chameleon archive is missing; skipping extraction."
    return 0
  fi

  safe_rm_rf "$temp"
  safe_rm_rf "$CHAMELEON_WORK_DIR"
  if ! extract_targz "$archive" "$temp" 2>"$LOGS_DIR/chameleon-extract-error.log"; then
    warn "Chameleon archive is not a valid tar.gz file: $archive"
    warn "Extractor details were written to logs/chameleon-extract-error.log"
    warn "Place a valid archive containing i386/boot0, i386/boot1h, and i386/boot at:"
    warn "  $CHAMELEON_MANUAL_ARCHIVE"
    safe_rm_rf "$temp"
    if [[ "$archive" == "$CHAMELEON_DOWNLOAD" ]]; then
      rm -f -- "$CHAMELEON_DOWNLOAD"
    fi
    return 0
  fi

  mv -- "$temp" "$CHAMELEON_WORK_DIR"
  if [[ -z "$(find_chameleon_i386 || true)" ]]; then
    warn "Chameleon archive extracted, but i386/boot0 was not found."
    warn "Place a valid archive containing i386/boot0, i386/boot1h, and i386/boot at:"
    warn "  $CHAMELEON_MANUAL_ARCHIVE"
    return 0
  fi

  log "Extracted Chameleon to $CHAMELEON_WORK_DIR"
}

find_chameleon_i386() {
  find "$CHAMELEON_WORK_DIR" -path '*/i386/boot0' -type f -print 2>/dev/null \
    | head -n 1 \
    | sed 's#/boot0$##'
}

require_chameleon_i386() {
  local i386
  i386="$(find_chameleon_i386 || true)"
  [[ -n "$i386" ]] || die "Missing Chameleon i386 boot files. Put chameleon-binaries.tar.gz in downloads/ and rerun --download-only."
  [[ -f "$i386/boot0" && -f "$i386/boot1h" && -f "$i386/boot" ]] || die "Chameleon i386 is incomplete: $i386"
  printf '%s\n' "$i386"
}

copy_tree() {
  local src="$1"
  local dest="$2"

  mkdir -p "$(dirname "$dest")"
  if have_cmd ditto; then
    ditto "$src" "$dest"
  else
    rm -rf -- "$dest"
    mkdir -p "$dest"
    cp -R "$src"/. "$dest"/
  fi
}

copy_tree_sudo() {
  local src="$1"
  local dest="$2"

  if have_cmd ditto; then
    sudo ditto "$src" "$dest"
  else
    sudo rm -rf -- "$dest"
    sudo mkdir -p "$dest"
    sudo cp -R "$src"/. "$dest"/
  fi
}

write_extra_plists() {
  local extra_dir="$1"

  mkdir -p "$extra_dir"
  cat >"$extra_dir/com.apple.Boot.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Timeout</key>
    <string>5</string>

    <key>Kernel Flags</key>
    <string>-v -f arch=i386 cpus=1</string>

    <key>GraphicsEnabler</key>
    <string>No</string>

    <key>USBBusFix</key>
    <string>Yes</string>

    <key>EHCIacquire</key>
    <string>Yes</string>

    <key>UHCIreset</key>
    <string>Yes</string>
</dict>
</plist>
EOF

  cat >"$extra_dir/smbios.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>SMproductname</key>
    <string>MacBook2,1</string>

    <key>SMbiosversion</key>
    <string>MB21.88Z.00A5.B07.0706270922</string>

    <key>SMfamily</key>
    <string>MacBook</string>

    <key>SMmanufacturer</key>
    <string>Apple Inc.</string>
</dict>
</plist>
EOF
}

find_kext() {
  local subdir="$1"
  local name="$2"
  find "$LEGACY_WORK_DIR/$subdir" -iname "$name" -type d -print -quit 2>/dev/null || true
}

copy_kext_to_dir() {
  local subdir="$1"
  local name="$2"
  local dest_dir="$3"
  local required="$4"
  local src

  src="$(find_kext "$subdir" "$name")"
  if [[ -z "$src" ]]; then
    if [[ "$required" == "yes" ]]; then
      die "Required kext not found in Legacy-Kexts/$subdir: $name"
    fi
    warn "Optional kext not found in Legacy-Kexts/$subdir: $name"
    return 1
  fi

  copy_tree "$src" "$dest_dir/$name"
}

copy_first_kext_to_dir() {
  local subdir="$1"
  local dest_dir="$2"
  local required="$3"
  shift 3

  local name
  local src
  for name in "$@"; do
    src="$(find_kext "$subdir" "$name")"
    if [[ -n "$src" ]]; then
      copy_tree "$src" "$dest_dir/$(basename "$src")"
      return 0
    fi
  done

  if [[ "$required" == "yes" ]]; then
    die "Required kext not found in Legacy-Kexts/$subdir. Tried: $*"
  fi
  warn "Optional kext not found in Legacy-Kexts/$subdir. Tried: $*"
  return 1
}

build_optional_injectors() {
  local dest="$OUTPUT_DIR/Optional-Injectors"
  local src
  local name

  safe_rm_rf "$dest"
  mkdir -p "$dest"
  for name in AHCIPortInjector.kext ATAPortInjector.kext SATA-unsupported.kext; do
    src="$(find_kext "Injectors" "$name")"
    if [[ -n "$src" ]]; then
      copy_tree "$src" "$dest/$name"
    else
      warn "Optional injector not found: $name"
    fi
  done
}

build_extra_template() {
  local extra_dir="$OUTPUT_DIR/Extra"
  local ext_dir="$extra_dir/Extensions"

  [[ -d "$LEGACY_WORK_DIR" ]] || die "Legacy-Kexts is not extracted. Run --download-only first."

  safe_rm_rf "$extra_dir"
  mkdir -p "$ext_dir"
  write_extra_plists "$extra_dir"

  copy_first_kext_to_dir "FAT" "$ext_dir" "yes" "FakeSMC.kext" "fakesmc.kext"
  copy_first_kext_to_dir "FAT" "$ext_dir" "yes" "NullCPUPowerManagement.kext"
  copy_first_kext_to_dir "FAT" "$ext_dir" "yes" "VoodooPS2.kext" "VoodooPS2Controller.kext"
  copy_first_kext_to_dir "FAT" "$ext_dir" "yes" "AppleACPIPS2Nub.kext"
  copy_first_kext_to_dir "FAT" "$ext_dir" "yes" "EvOreboot.kext"
  copy_first_kext_to_dir "FAT" "$ext_dir" "yes" "VoodooHDA.kext"

  if ! copy_first_kext_to_dir "32Bit-only" "$ext_dir" "no" "ACPIBatteryManager.kext" "AppleACPIBatteryManager.kext"; then
    copy_first_kext_to_dir "32Bit-only" "$ext_dir" "yes" "VoodooBattery.kext"
  fi

  build_optional_injectors
  log "Built Extra template at $extra_dir"
}

create_next_steps() {
  cat >"$OUTPUT_DIR/README_NEXT_STEPS.txt" <<'EOF'
Acer Aspire 4310 Leopard USB next steps
=======================================

1. Insert this USB drive into the Acer Aspire 4310.
2. In BIOS, enable USB Boot and F12 Boot Menu. Enable AHCI if that option exists.
3. Boot from USB.
4. In Chameleon, choose "Mac OS X Install DVD".
5. Boot flags:
   -v -f arch=i386 cpus=1
6. In the installer, use Disk Utility to create an HFS+ target volume, for example LeopardHD.
7. Install Mac OS X Leopard from your retail media.
8. After reboot, boot from USB again and choose LeopardHD in Chameleon.
9. If it boots, install MacOSXUpdCombo10.5.8.dmg from the TOOLS partition.
10. After the update, boot through USB into LeopardHD again.
11. Run --install-chameleon-hdd to generate HDD Chameleon commands, or install Chameleon manually.
12. If you see "Still waiting for root device", copy AHCIPortInjector/ATAPortInjector/SATA-unsupported
    from TOOLS/Optional-Injectors to CHAMUSB/Extra/Extensions, fix ownership/permissions, and reboot.
13. If boot hangs on AppleIntelCPUPowerManagement, verify NullCPUPowerManagement.kext.
14. If boot hangs before DSMOS, verify FakeSMC.kext.
15. If keyboard/touchpad do not work, verify VoodooPS2.kext and AppleACPIPS2Nub.kext.
16. If audio is missing, start with VoodooHDA.kext. Look for ALC268-specific fixes later.
17. BCM5787M Ethernet is not required for installation. Use Wi-Fi, USB Ethernet, or search separately
    for AppleBCM5751Ethernet/BCM5787M support.
EOF
}

validate_downloads() {
  [[ -s "$APPLE_1058_DMG" ]] || warn "MacOSXUpdCombo10.5.8.dmg is missing."
  [[ -s "$LEGACY_ZIP" ]] || warn "Legacy-Kexts-master.zip is missing."
  [[ -d "$LEGACY_WORK_DIR" ]] || warn "Legacy-Kexts was not extracted."

  if [[ -z "$(find_chameleon_i386 || true)" ]]; then
    warn "Chameleon boot files are not ready. make-usb will stop until boot0/boot1h/boot are available."
  fi

  [[ -f "$OUTPUT_DIR/README_NEXT_STEPS.txt" ]] || warn "README_NEXT_STEPS.txt was not generated."
}

run_download_only() {
  ensure_dirs
  download_apple_1058_combo
  download_apple_1056_combo_optional
  download_legacy_kexts
  extract_legacy_kexts
  download_chameleon || true
  extract_chameleon
  build_extra_template
  create_next_steps
  validate_downloads
  log "download-only completed. Review warnings above, if any."
}

run_list_disks() {
  require_macos
  require_cmd diskutil
  diskutil list
  cat <<'EOF'

WARNING:
  The --make-usb mode will destroy the selected USB disk after exact confirmation.
  Verify the disk identifier carefully. You will need to type exactly:
    ERASE /dev/diskX
EOF
}

validate_disk_identifier() {
  local disk="$1"
  [[ "$disk" =~ ^/dev/disk[0-9]+$ ]] || die "--disk must be a whole disk like /dev/disk2, not a partition/slice."
}

disk_info_text() {
  local disk="$1"
  diskutil info "$disk"
}

assert_external_usb_disk() {
  local disk="$1"
  local info

  info="$(disk_info_text "$disk")" || die "diskutil info failed for $disk"
  printf '%s\n' "$info"

  if ! printf '%s\n' "$info" | grep -Eq 'Protocol:[[:space:]]*USB|External:[[:space:]]*Yes|Device Location:[[:space:]]*External|Removable Media:[[:space:]]*Removable'; then
    die "$disk does not look like an external USB/removable disk. Refusing to continue."
  fi
}

confirm_erase() {
  local disk="$1"
  local answer

  printf '\nAbout to erase and repartition %s as MBR with CHAMUSB, LEOPARD, and TOOLS.\n' "$disk"
  printf 'Type exactly this confirmation string to continue: ERASE %s\n> ' "$disk"
  IFS= read -r answer
  [[ "$answer" == "ERASE $disk" ]] || die "Confirmation did not match. No disk changes were made."
}

raw_device() {
  local dev="$1"
  local node="${dev#/dev/}"
  printf '/dev/r%s\n' "$node"
}

slice_for() {
  local disk="$1"
  local n="$2"
  printf '%ss%s\n' "$disk" "$n"
}

mount_point_for_slice() {
  local slice="$1"
  local mount

  mount="$(diskutil info "$slice" | awk -F': *' '/Mount Point/ { print $2; exit }')"
  if [[ -z "$mount" || "$mount" == "Not mounted" ]]; then
    return 1
  fi
  printf '%s\n' "$mount"
}

ensure_slice_mounted() {
  local slice="$1"
  local mount

  diskutil mount "$slice" >/dev/null 2>&1 || true
  mount="$(mount_point_for_slice "$slice" || true)"
  [[ -n "$mount" ]] || die "Could not mount $slice"
  printf '%s\n' "$mount"
}

attach_retail_image() {
  local image="$1"
  local attach_out
  local volume

  attach_out="$(hdiutil attach -nobrowse -readonly "$image")" || die "hdiutil attach failed for $image"
  printf '%s\n' "$attach_out" >"$LOGS_DIR/hdiutil-attach.log"

  ATTACHED_IMAGE_DEVICE="$(printf '%s\n' "$attach_out" | awk '/^\/dev\// { print $1; exit }')"
  volume="$(printf '%s\n' "$attach_out" | awk '/\/Volumes\// { print substr($0, index($0, "/Volumes/")); exit }')"
  [[ -n "$volume" ]] || die "Could not find mounted volume from hdiutil output."
  printf '%s\n' "$volume"
}

restore_retail_to_leopard() {
  local retail="$1"
  local target_mount="$2"
  local lower
  local source="$retail"
  local image_for_scan=""

  lower="$(printf '%s' "$retail" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.dmg|*.iso)
      source="$(attach_retail_image "$retail")"
      image_for_scan="$retail"
      ;;
  esac

  log "Restoring retail Leopard source to $target_mount"
  if sudo asr restore --source "$source" --target "$target_mount" --erase --noprompt; then
    return 0
  fi

  if [[ -n "$image_for_scan" ]]; then
    warn "asr restore failed. Running asr imagescan on the source image and retrying."
    sudo asr imagescan --source "$image_for_scan" || die "asr imagescan failed for $image_for_scan"
    sudo asr restore --source "$image_for_scan" --target "$target_mount" --erase --noprompt \
      || die "asr restore failed after imagescan."
    return 0
  fi

  die "asr restore failed."
}

install_chameleon_to_usb_partition() {
  local disk="$1"
  local cham_slice="$2"
  local i386="$3"
  local raw_disk
  local raw_cham_slice
  local fdisk_script
  local cham_mount

  raw_disk="$(raw_device "$disk")"
  raw_cham_slice="$(raw_device "$cham_slice")"

  log "Installing Chameleon boot0/boot1h/boot to CHAMUSB"
  diskutil unmountDisk "$disk"
  sudo fdisk -f "$i386/boot0" -u -y "$raw_disk"
  sudo dd if="$i386/boot1h" of="$raw_cham_slice" bs=512 count=1

  fdisk_script="$WORK_DIR/fdisk-activate-chamusb.txt"
  cat >"$fdisk_script" <<'EOF'
print
flag 1
write
quit
EOF

  if ! sudo fdisk -e "$raw_disk" <"$fdisk_script"; then
    warn "Automatic fdisk active-flag step failed. Run manually:"
    warn "  sudo fdisk -e $raw_disk"
    warn "  print"
    warn "  flag 1"
    warn "  write"
    warn "  quit"
  fi

  cham_mount="$(ensure_slice_mounted "$cham_slice")"
  sudo cp "$i386/boot" "$cham_mount/boot"
  copy_tree_sudo "$i386" "$cham_mount/i386"
}

install_extra_to_chamusb() {
  local cham_mount="$1"

  build_extra_template
  sudo rm -rf -- "$cham_mount/Extra"
  copy_tree_sudo "$OUTPUT_DIR/Extra" "$cham_mount/Extra"
  sudo chown -R root:wheel "$cham_mount/Extra"
  sudo chmod -R 755 "$cham_mount/Extra"
}

copy_tools_to_partition() {
  local tools_mount="$1"
  local cham_mount="$2"

  create_next_steps
  sudo mkdir -p "$tools_mount/Updates" "$tools_mount/Archives"

  [[ -s "$APPLE_1058_DMG" ]] && sudo cp "$APPLE_1058_DMG" "$tools_mount/Updates/" || warn "10.5.8 Combo Update missing; not copied to TOOLS."
  [[ -s "$APPLE_1056_DMG" ]] && sudo cp "$APPLE_1056_DMG" "$tools_mount/Updates/" || true
  [[ -s "$LEGACY_ZIP" ]] && sudo cp "$LEGACY_ZIP" "$tools_mount/Archives/" || warn "Legacy-Kexts zip missing; not copied to TOOLS."

  [[ -d "$LEGACY_WORK_DIR" ]] && copy_tree_sudo "$LEGACY_WORK_DIR" "$tools_mount/Legacy-Kexts"
  [[ -d "$CHAMELEON_WORK_DIR" ]] && copy_tree_sudo "$CHAMELEON_WORK_DIR" "$tools_mount/chameleon"
  [[ -d "$OUTPUT_DIR/Optional-Injectors" ]] && copy_tree_sudo "$OUTPUT_DIR/Optional-Injectors" "$tools_mount/Optional-Injectors"
  [[ -d "$cham_mount/Extra" ]] && copy_tree_sudo "$cham_mount/Extra" "$tools_mount/Extra-backup"
  sudo cp "$OUTPUT_DIR/README_NEXT_STEPS.txt" "$tools_mount/README_NEXT_STEPS.txt"
}

prepare_assets_for_usb() {
  ensure_dirs
  if [[ ! -d "$LEGACY_WORK_DIR" ]]; then
    extract_legacy_kexts
  fi
  if [[ -z "$(find_chameleon_i386 || true)" ]]; then
    extract_chameleon
  fi
  require_chameleon_i386 >/dev/null
  build_extra_template
  create_next_steps
}

run_make_usb() {
  local i386
  local cham_slice
  local leopard_slice
  local tools_slice
  local leopard_mount
  local cham_mount
  local tools_mount

  require_macos
  require_cmd diskutil
  require_cmd hdiutil
  require_cmd asr
  require_cmd fdisk
  require_cmd dd

  [[ -n "$DISK" ]] || die "--make-usb requires --disk /dev/diskX"
  [[ -n "$RETAIL" ]] || die "--make-usb requires --retail /path/to/Leopard.dmg|iso|volume"
  [[ -e "$RETAIL" ]] || die "Retail source does not exist: $RETAIL"
  validate_disk_identifier "$DISK"
  prepare_assets_for_usb
  i386="$(require_chameleon_i386)"

  assert_external_usb_disk "$DISK"
  confirm_erase "$DISK"

  log "Partitioning $DISK"
  diskutil partitionDisk "$DISK" MBR \
    JHFS+ CHAMUSB 512M \
    JHFS+ LEOPARD 9G \
    JHFS+ TOOLS R

  cham_slice="$(slice_for "$DISK" 1)"
  leopard_slice="$(slice_for "$DISK" 2)"
  tools_slice="$(slice_for "$DISK" 3)"
  leopard_mount="$(ensure_slice_mounted "$leopard_slice")"

  restore_retail_to_leopard "$RETAIL" "$leopard_mount"

  diskutil mount "$cham_slice" >/dev/null 2>&1 || true
  diskutil mount "$tools_slice" >/dev/null 2>&1 || true
  install_chameleon_to_usb_partition "$DISK" "$cham_slice" "$i386"

  cham_mount="$(ensure_slice_mounted "$cham_slice")"
  tools_mount="$(ensure_slice_mounted "$tools_slice")"
  install_extra_to_chamusb "$cham_mount"
  copy_tools_to_partition "$tools_mount" "$cham_mount"

  sync
  cat <<EOF

USB creation completed.

On the Acer Aspire 4310:
  1. Boot from USB.
  2. In Chameleon, choose "Mac OS X Install DVD".
  3. Use boot flags: -v -f arch=i386 cpus=1

Next steps are also on the TOOLS partition:
  README_NEXT_STEPS.txt
EOF
}

quote_arg() {
  printf '%q' "$1"
}

raw_for_generated_command() {
  raw_device "$1"
}

generate_hdd_commands() {
  local target="$1"
  local disk="$2"
  local slice="$3"
  local i386="$4"
  local raw_disk
  local raw_slice
  local out="$OUTPUT_DIR/install_chameleon_hdd_commands.sh"

  raw_disk="$(raw_for_generated_command "$disk")"
  raw_slice="$(raw_for_generated_command "$slice")"
  mkdir -p "$OUTPUT_DIR"

  cat >"$out" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

I386=$(quote_arg "$i386")
TARGET=$(quote_arg "$target")
DISK=$(quote_arg "$disk")
SLICE=$(quote_arg "$slice")
RAW_DISK=$(quote_arg "$raw_disk")
RAW_SLICE=$(quote_arg "$raw_slice")
EXTRA_SOURCE=$(quote_arg "$OUTPUT_DIR/Extra")

diskutil unmountDisk "\$DISK"
sudo fdisk -f "\$I386/boot0" -u -y "\$RAW_DISK"
sudo dd if="\$I386/boot1h" of="\$RAW_SLICE" bs=512 count=1
diskutil mount "\$SLICE"
sudo cp "\$I386/boot" "\$TARGET/boot"
if command -v ditto >/dev/null 2>&1; then
  sudo ditto "\$EXTRA_SOURCE" "\$TARGET/Extra"
else
  sudo rm -rf "\$TARGET/Extra"
  sudo mkdir -p "\$TARGET/Extra"
  sudo cp -R "\$EXTRA_SOURCE"/. "\$TARGET/Extra"/
fi
sudo chown -R root:wheel "\$TARGET/Extra"
sudo chmod -R 755 "\$TARGET/Extra"
EOF
  chmod +x "$out"
  printf '%s\n' "$out"
}

run_install_chameleon_hdd() {
  local i386
  local out
  local confirm

  require_macos
  require_cmd diskutil
  require_cmd fdisk
  require_cmd dd

  [[ -n "$TARGET" ]] || die "--install-chameleon-hdd requires --target /Volumes/LeopardHD"
  [[ -n "$DISK" ]] || die "--install-chameleon-hdd requires --disk /dev/disk0"
  [[ -n "$SLICE" ]] || die "--install-chameleon-hdd requires --slice /dev/disk0s2"
  [[ -d "$TARGET" ]] || die "Target volume does not exist: $TARGET"
  validate_disk_identifier "$DISK"
  [[ "$SLICE" =~ ^/dev/disk[0-9]+s[0-9]+$ ]] || die "--slice must look like /dev/disk0s2"

  prepare_assets_for_usb
  i386="$(require_chameleon_i386)"
  out="$(generate_hdd_commands "$TARGET" "$DISK" "$SLICE" "$i386")"

  cat <<EOF
Generated HDD Chameleon command script:
  $out

The commands were NOT executed.
Review them before running manually.
EOF

  if [[ "$EXECUTE_HDD" -eq 1 ]]; then
    printf '\nTo execute now, type exactly: INSTALL CHAMELEON %s %s\n> ' "$DISK" "$SLICE"
    IFS= read -r confirm
    [[ "$confirm" == "INSTALL CHAMELEON $DISK $SLICE" ]] || die "Confirmation did not match. Commands were not executed."
    "$out"
  fi
}

set_mode() {
  local next="$1"
  if [[ -n "$MODE" && "$MODE" != "$next" ]]; then
    die "Choose only one mode."
  fi
  MODE="$next"
}

while (($#)); do
  case "$1" in
    --download-only)
      set_mode "download-only"
      ;;
    --list-disks)
      set_mode "list-disks"
      ;;
    --make-usb)
      set_mode "make-usb"
      ;;
    --install-chameleon-hdd)
      set_mode "install-chameleon-hdd"
      ;;
    --disk)
      shift
      [[ $# -gt 0 ]] || die "--disk requires a value"
      DISK="$1"
      ;;
    --retail)
      shift
      [[ $# -gt 0 ]] || die "--retail requires a value"
      RETAIL="$1"
      ;;
    --target)
      shift
      [[ $# -gt 0 ]] || die "--target requires a value"
      TARGET="$1"
      ;;
    --slice)
      shift
      [[ $# -gt 0 ]] || die "--slice requires a value"
      SLICE="$1"
      ;;
    --execute)
      EXECUTE_HDD=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

case "$MODE" in
  download-only)
    run_download_only
    ;;
  list-disks)
    run_list_disks
    ;;
  make-usb)
    run_make_usb
    ;;
  install-chameleon-hdd)
    run_install_chameleon_hdd
    ;;
  "")
    usage
    exit 1
    ;;
esac
