#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET="asus-eee-pc-1215p"
PROFILE_DIR="$ROOT_DIR/profiles/$TARGET/snowleopard"
HARDWARE_CONF="$ROOT_DIR/profiles/$TARGET/hardware.conf"
PROFILE_CONF="$PROFILE_DIR/profile.conf"
KEXT_MANIFEST="$PROFILE_DIR/kexts.conf"
CACHE_DIR="$ROOT_DIR/cache"
DOWNLOADS_DIR="$ROOT_DIR/downloads"
CURRENT_SOURCES="$CACHE_DIR/current-sources.env"
BUILD_ROOT="$ROOT_DIR/output/$TARGET/snowleopard/opencore-custom"
KERNEL_DEFAULT="$ROOT_DIR/input/kernels/snowleopard/asus-eee-pc-1215p-kernel"
KERNEL_FILE="$KERNEL_DEFAULT"
CONFIG_GENERATOR="$ROOT_DIR/scripts/generate_oc_config.py"
CONFIG_PATCHER="$ROOT_DIR/scripts/patch_asus_1215p_oc_config.py"
TREE_VALIDATOR="$ROOT_DIR/scripts/validate_oc_tree.py"
INSPECTOR="$ROOT_DIR/scripts/inspect_artifact.py"
KERNEL_FETCHER="$ROOT_DIR/scripts/fetch_atom_1063_kernel.sh"
COMMON_ASSET_ENGINE="$ROOT_DIR/prepare_aspire4310_macos.sh"

MODE=""
BOOT_PRESET="diagnostic"
KEXT_SET="minimal"
SATA_MODE="native"
DISK=""
RETAIL=""
DRY_RUN=0
ALLOW_INTERNAL=0
PROTECTED_VOLUMES=()
ATTACHED_IMAGE_DEVICE=""
ATTACHED_RETAIL_VOLUME=""

log() { printf '[asus1215p] %s\n' "$*"; }
warn() { printf '[asus1215p] WARNING: %s\n' "$*" >&2; }
die() { printf '[asus1215p] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  if [[ -n "$ATTACHED_IMAGE_DEVICE" && "$(uname -s 2>/dev/null || true)" == Darwin ]]; then
    hdiutil detach "$ATTACHED_IMAGE_DEVICE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'USAGE'
ASUS Eee PC 1215P / Snow Leopard 10.6.3 bring-up engine

Read-only:
  --doctor
  --list-disks
  --verify-usb --disk /dev/diskX

Project operations:
  --download
  --build [--kernel-file /path/to/i386-kernel]

Destructive USB creation (macOS only):
  --make-usb --disk /dev/diskX --retail /path/to/SnowLeopard10.6.3.iso

Options:
  --kernel-file PATH
  --boot-preset normal|verbose|safe|diagnostic
  --kext-set minimal|full
  --sata native|injected
  --protect-volume /Volumes/KEEP
  --dry-run
  --allow-internal

--download reuses the shared OpenCore/OcBinaryData/Legacy-Kexts cache and then
tries to retrieve a historical Darwin 10.3.0 i386 legacy-kernel candidate.
Retail Mac OS X media is never downloaded by this project.
USAGE
}

need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }
set_mode() { [[ -z "$MODE" || "$MODE" == "$1" ]] || die "Choose exactly one operation"; MODE="$1"; }

[[ -f "$HARDWARE_CONF" && -f "$PROFILE_CONF" && -f "$KEXT_MANIFEST" ]] || die "ASUS 1215P profile is incomplete"
# shellcheck disable=SC1090
source "$HARDWARE_CONF"
# shellcheck disable=SC1090
source "$PROFILE_CONF"

while (($#)); do
  case "$1" in
    --doctor) set_mode doctor ;;
    --download|--download-only) set_mode download ;;
    --build) set_mode build ;;
    --list-disks) set_mode list-disks ;;
    --make-usb) set_mode make-usb ;;
    --verify-usb|--verify) set_mode verify-usb ;;
    --kernel-file) need_value "$@"; shift; KERNEL_FILE="$1" ;;
    --boot-preset) need_value "$@"; shift; BOOT_PRESET="$1" ;;
    --kext-set) need_value "$@"; shift; KEXT_SET="$1" ;;
    --sata) need_value "$@"; shift; SATA_MODE="$1" ;;
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --retail) need_value "$@"; shift; RETAIL="$1" ;;
    --protect-volume) need_value "$@"; shift; PROTECTED_VOLUMES+=("$1") ;;
    --dry-run) DRY_RUN=1 ;;
    --allow-internal) ALLOW_INTERNAL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

case "$BOOT_PRESET" in normal|verbose|safe|diagnostic) ;; *) die "Invalid --boot-preset" ;; esac
case "$KEXT_SET" in minimal|full) ;; *) die "--kext-set must be minimal or full" ;; esac
case "$SATA_MODE" in native|injected) ;; *) die "--sata must be native or injected" ;; esac

validate_kernel() {
  local kernel="$1"
  [[ -s "$kernel" ]] || return 1
  file "$kernel" | grep -Eqi 'Mach-O.*i386|Mach-O universal.*i386' || return 1
  strings "$kernel" | grep -Eq 'Darwin Kernel Version 10\.3\.0|xnu-1504\.3\.12' || return 1
}

load_sources() {
  [[ -f "$CURRENT_SOURCES" ]] || die "Common assets are missing. Run --download first."
  # shellcheck disable=SC1090
  source "$CURRENT_SOURCES"
  OC_CACHE_ROOT="$CACHE_DIR/$OC_CACHE_REL"
  LEGACY_KEXTS_ROOT="$CACHE_DIR/$LEGACY_KEXTS_CACHE_REL"
  [[ -f "$OC_CACHE_ROOT/Docs/Sample.plist" ]] || die "OpenCore cache is incomplete"
  [[ -d "$OC_CACHE_ROOT/IA32/EFI/OC" ]] || die "Cached OpenCore release has no IA32 tree"
  [[ -d "$LEGACY_KEXTS_ROOT/FAT" ]] || die "Legacy-Kexts cache is incomplete"
  [[ -f "$DOWNLOADS_DIR/$HFS_32_FILE" ]] || die "HfsPlus32.efi cache is missing"
}

run_doctor() {
  local failures=0 c
  printf 'Target: %s\n' "$TARGET_MODEL"
  printf 'CPU: %s (%sC/%sT, CPUID %s)\n' "$TARGET_CPU" "$TARGET_CPU_CORES" "$TARGET_CPU_THREADS" "$TARGET_CPU_CPUID"
  printf 'GPU: %s\nPanel: %s\n' "$TARGET_GPU" "$TARGET_DISPLAY"
  printf 'Ethernet: %s\nWi-Fi: %s\nAudio: %s\n' "$TARGET_ETHERNET" "$TARGET_WIFI" "$TARGET_AUDIO"
  printf 'BIOS: %s\nSnow Leopard baseline: %s / i386 custom kernel\n' "$TARGET_FIRMWARE" "$OS_BASELINE"
  printf '\nRequired build tools:\n'
  for c in bash python3 file strings find cp mkdir; do
    if have "$c"; then printf '  OK      %s\n' "$c"; else printf '  MISSING %s\n' "$c"; failures=$((failures+1)); fi
  done
  if [[ -f "$CURRENT_SOURCES" ]]; then
    printf '  OK      shared OpenCore asset metadata\n'
  else
    printf '  MISSING shared assets (run --download)\n'
    failures=$((failures+1))
  fi
  if validate_kernel "$KERNEL_FILE"; then
    printf '  OK      Darwin 10.3.0 i386 kernel: %s\n' "$KERNEL_FILE"
  else
    printf '  MISSING/INVALID Darwin 10.3.0 i386 kernel\n'
    printf '          expected: %s\n' "$KERNEL_FILE"
    failures=$((failures+1))
  fi
  if [[ "$(uname -s 2>/dev/null || true)" == Darwin ]]; then
    for c in diskutil hdiutil asr plutil ditto; do
      if have "$c"; then printf '  OK      %s\n' "$c"; else printf '  MISSING %s\n' "$c"; failures=$((failures+1)); fi
    done
  else
    printf '  NOTE    USB writing requires macOS.\n'
  fi
  printf '\nFirst boot: native 27C1 AHCI, FakeSMC + PS/2, GMA3150 spoof; network/audio/battery remain optional.\n'
  (( failures == 0 ))
}

run_download() {
  log "Preparing shared OpenCore/OcBinaryData/Legacy-Kexts cache"
  bash "$COMMON_ASSET_ENGINE" --download --skip-combo-updates
  log "Fetching and validating a historical Darwin 10.3.0 i386 kernel candidate"
  bash "$KERNEL_FETCHER" "$KERNEL_DEFAULT"
}

copy_tree() {
  local src="$1" dst="$2"
  if have ditto; then ditto "$src" "$dst"; else mkdir -p "$dst"; cp -R "$src"/. "$dst"/; fi
}

copy_kexts() {
  local dst="$1" set_name source_path static_status purpose src out exe
  while IFS=$'\t' read -r set_name source_path static_status purpose; do
    [[ -n "$set_name" && "$set_name" != \#* ]] || continue
    case "$set_name" in
      smc|minimal) ;;
      full) [[ "$KEXT_SET" == full ]] || continue ;;
      sata) [[ "$SATA_MODE" == injected ]] || continue ;;
      *) continue ;;
    esac
    src="$LEGACY_KEXTS_ROOT/$source_path"
    [[ -d "$src" ]] || die "Missing legacy kext candidate: $src"
    out="$dst/$(basename "$src")"
    [[ ! -e "$out" ]] || die "Kext basename collision: $out"
    copy_tree "$src" "$out"
    python3 "$INSPECTOR" --kext "$out" --quiet >/dev/null || die "Invalid kext bundle: $out"
    exe="$(python3 - "$out/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f: d=plistlib.load(f)
print(d.get('CFBundleExecutable',''))
PY
)"
    if [[ -n "$exe" ]]; then
      python3 "$INSPECTOR" --kext "$out" --require-arch i386 --quiet || die "Kext has no usable i386 slice: $out"
    fi
    log "kext: $(basename "$out") [$static_status] - $purpose"
  done <"$KEXT_MANIFEST"
}

collect_kexts() {
  find "$1" -type d -name '*.kext' -print | sed "s#^$1/##" | LC_ALL=C sort
}

run_build() {
  local ocroot esp archsrc validator rel
  local -a args
  load_sources
  validate_kernel "$KERNEL_FILE" || die "Valid Darwin 10.3.0 i386 kernel required. Run --download or pass --kernel-file."
  rm -rf -- "$BUILD_ROOT"
  esp="$BUILD_ROOT/ESP"
  ocroot="$esp/EFI/OC"
  archsrc="$OC_CACHE_ROOT/IA32"
  mkdir -p "$esp/EFI/BOOT" "$ocroot/ACPI" "$ocroot/Drivers" "$ocroot/Kexts" "$ocroot/Tools" "$esp/Kernels" "$BUILD_ROOT/OpenDuet"

  cp -p "$archsrc/EFI/BOOT/"*.efi "$esp/EFI/BOOT/"
  printf '%s' Disabled >"$esp/EFI/BOOT/.contentVisibility"
  cp -p "$archsrc/EFI/OC/OpenCore.efi" "$ocroot/OpenCore.efi"
  cp -p "$archsrc/EFI/OC/Drivers/OpenRuntime.efi" "$ocroot/Drivers/OpenRuntime.efi"
  cp -p "$archsrc/EFI/OC/Drivers/Ps2KeyboardDxe.efi" "$ocroot/Drivers/Ps2KeyboardDxe.efi"
  cp -p "$archsrc/EFI/OC/Drivers/Ps2MouseDxe.efi" "$ocroot/Drivers/Ps2MouseDxe.efi"
  cp -p "$DOWNLOADS_DIR/$HFS_32_FILE" "$ocroot/Drivers/HfsPlus32.efi"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/bootIA32" "$esp/boot"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/BootInstall_IA32.tool" "$BUILD_ROOT/OpenDuet/"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/BootInstallBase.sh" "$BUILD_ROOT/OpenDuet/"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/boot0" "$BUILD_ROOT/OpenDuet/"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/boot1f32" "$BUILD_ROOT/OpenDuet/"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/bootIA32" "$BUILD_ROOT/OpenDuet/"

  cp -p "$KERNEL_FILE" "$esp/Kernels/kernel"
  copy_kexts "$ocroot/Kexts"

  args=(
    --sample "$OC_CACHE_ROOT/Docs/Sample.plist"
    --output "$ocroot/config.plist"
    --oc-root "$ocroot"
    --os snowleopard
    --kernel custom
    --boot-preset "$BOOT_PRESET"
    --runtime-profile modern
    --oc-version "$OC_VERSION"
    --driver OpenRuntime.efi
    --driver HfsPlus32.efi
    --driver Ps2KeyboardDxe.efi
    --driver Ps2MouseDxe.efi
  )
  while IFS= read -r rel; do [[ -n "$rel" ]] && args+=(--kext "$rel"); done < <(collect_kexts "$ocroot/Kexts")
  python3 "$CONFIG_GENERATOR" "${args[@]}"
  python3 "$CONFIG_PATCHER" "$ocroot/config.plist"
  python3 "$TREE_VALIDATOR" "$ocroot/config.plist"

  if [[ "$(uname -s 2>/dev/null || true)" == Darwin ]]; then
    validator="$OC_CACHE_ROOT/Utilities/ocvalidate/ocvalidate"
  else
    validator="$OC_CACHE_ROOT/Utilities/ocvalidate/ocvalidate.linux"
  fi
  if [[ -f "$validator" ]]; then
    chmod +x "$validator" 2>/dev/null || true
    "$validator" "$ocroot/config.plist"
  else
    warn "ocvalidate not available for this host"
  fi

  python3 "$CONFIG_PATCHER" --check "$ocroot/config.plist"
  python3 - "$ocroot/config.plist" "$esp/Kernels/kernel" <<'PY'
import hashlib,plistlib,sys
cfg=plistlib.load(open(sys.argv[1],'rb'))
assert cfg['Kernel']['Scheme']['KernelArch']=='i386'
assert cfg['Kernel']['Scheme']['CustomKernel'] is True
assert cfg['DeviceProperties']['Add']['PciRoot(0x0)/Pci(0x2,0x0)']['device-id']==bytes.fromhex('A2270000')
print('ASUS 1215P config assertions: PASS')
print('kernel sha256:', hashlib.sha256(open(sys.argv[2],'rb').read()).hexdigest())
PY

  cat >"$BUILD_ROOT/BUILD_REPORT.md" <<EOF
# ASUS Eee PC 1215P Snow Leopard bring-up build

- Target: $TARGET_MODEL
- CPU: $TARGET_CPU, $TARGET_CPU_CORES cores / $TARGET_CPU_THREADS threads, CPUID $TARGET_CPU_CPUID
- BIOS: $TARGET_FIRMWARE
- GPU: $TARGET_GPU
- Panel: $TARGET_DISPLAY
- SATA: $TARGET_SATA
- Ethernet: $TARGET_ETHERNET
- Wi-Fi: $TARGET_WIFI
- Audio: $TARGET_AUDIO
- OpenCore: $OC_VERSION IA32/OpenDuet
- Kernel: externally verified Darwin 10.3.0 i386 custom kernel
- KernelArch: i386
- First-boot kext set: $KEXT_SET
- SATA policy: $SATA_MODE
- GMA3150: 0x27A2 spoof + single-link laptop properties + cursor-corruption patch
- PCI0._UID patch: not required; physical DSDT already reports Zero

This is a hardware bring-up build. GMA3150 native framebuffer behavior must still be proven on OS X.
EOF
  log "Built and validated: $BUILD_ROOT"
}

require_macos() {
  [[ "$(uname -s 2>/dev/null || true)" == Darwin ]] || die "This operation requires macOS"
  local c
  for c in diskutil hdiutil asr ditto plutil; do have "$c" || die "Missing $c"; done
}

validate_disk() { [[ "$1" =~ ^/dev/disk[0-9]+$ ]] || die "Whole disk required, e.g. /dev/disk2"; }

is_protected_volume() {
  local p
  for p in "${PROTECTED_VOLUMES[@]}"; do [[ "${1%/}" == "${p%/}" ]] && return 0; done
  return 1
}

disk_has_protected_volume() {
  local slice mp
  while IFS= read -r slice; do
    mp="$(diskutil info "$slice" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}')"
    [[ -n "$mp" && "$mp" != 'Not mounted' ]] || continue
    is_protected_volume "$mp" && return 0
  done < <(diskutil list "$1" | awk '/[0-9]+:[[:space:]]/ {print "/dev/"$NF}' | grep -E '^/dev/disk[0-9]+s[0-9]+$' || true)
  return 1
}

assert_safe_disk() {
  local info internal
  info="$(diskutil info "$DISK")" || die "Cannot inspect $DISK"
  printf '%s\n\n' "$info"
  diskutil list "$DISK"
  disk_has_protected_volume "$DISK" && die "$DISK contains a --protect-volume mount"
  internal="$(printf '%s\n' "$info" | awk -F': *' '/Internal:/ {print $2; exit}')"
  [[ "$internal" != Yes* || "$ALLOW_INTERNAL" -eq 1 ]] || die "Refusing internal disk without --allow-internal"
  if ! printf '%s\n' "$info" | grep -Eq 'External:[[:space:]]*Yes|Device Location:[[:space:]]*External|Removable Media:[[:space:]]*Removable'; then
    [[ "$ALLOW_INTERNAL" -eq 1 ]] || die "Disk is not clearly external/removable"
  fi
}

attach_retail() {
  local out
  out="$(hdiutil attach -nobrowse -readonly "$1")"
  ATTACHED_IMAGE_DEVICE="$(printf '%s\n' "$out" | awk '/^\/dev\// {print $1; exit}')"
  ATTACHED_RETAIL_VOLUME="$(printf '%s\n' "$out" | awk '/\/Volumes\// {print substr($0,index($0,"/Volumes/")); exit}')"
  [[ -n "$ATTACHED_RETAIL_VOLUME" ]] || die "Could not locate mounted retail volume"
}

restore_retail() {
  local source="$1" target="$2"
  attach_retail "$source"
  if ! sudo asr restore --source "$ATTACHED_RETAIL_VOLUME" --target "$target" --erase --noprompt; then
    warn "Mounted-volume restore failed; image-scanning and retrying source image"
    sudo asr imagescan --source "$source"
    sudo asr restore --source "$source" --target "$target" --erase --noprompt
  fi
}

install_efi() {
  local slice="$1" mountp disknum boottool backup
  diskutil mount "$slice" >/dev/null 2>&1 || true
  mountp="$(diskutil info "$slice" | awk -F': *' '/Mount Point/ {print $2; exit}')"
  [[ -d "$mountp" ]] || die "EFI mount point not found"
  if [[ -d "$mountp/EFI" || -d "$mountp/Kernels" || -f "$mountp/boot" ]]; then
    backup="$ROOT_DIR/backup/asus1215p-usb-$(date '+%Y%m%d-%H%M%S')-$(basename "$DISK")"
    mkdir -p "$backup"
    [[ -d "$mountp/EFI" ]] && ditto "$mountp/EFI" "$backup/EFI" || true
    [[ -d "$mountp/Kernels" ]] && ditto "$mountp/Kernels" "$backup/Kernels" || true
    [[ -f "$mountp/boot" ]] && cp -p "$mountp/boot" "$backup/boot" || true
    sudo rm -rf -- "$mountp/EFI" "$mountp/Kernels"
  fi
  sudo ditto "$BUILD_ROOT/ESP/EFI" "$mountp/EFI"
  sudo ditto "$BUILD_ROOT/ESP/Kernels" "$mountp/Kernels"
  sudo cp -p "$BUILD_ROOT/ESP/boot" "$mountp/boot"
  [[ -f "$mountp/EFI/OC/config.plist" && -f "$mountp/EFI/BOOT/BOOTIA32.efi" && -f "$mountp/Kernels/kernel" ]] || die "EFI/custom-kernel copy verification failed"
  disknum="${DISK#/dev/disk}"
  boottool="$OC_CACHE_ROOT/Utilities/LegacyBoot/BootInstall_IA32.tool"
  chmod +x "$boottool" "$OC_CACHE_ROOT/Utilities/LegacyBoot/BootInstallBase.sh"
  printf '%s\n' "$disknum" | "$boottool"
  sync
}

run_list_disks() { require_macos; diskutil list; }

run_make_usb() {
  local efi_slice installer_slice answer candidate
  require_macos
  [[ -n "$DISK" ]] || die "--make-usb requires --disk"
  validate_disk "$DISK"
  if [[ -z "$RETAIL" ]]; then
    for candidate in "$ROOT_DIR/input/SnowLeopard-Retail.iso" "$ROOT_DIR/input/SnowLeopard-Retail.dmg"; do
      [[ -e "$candidate" ]] && RETAIL="$candidate" && break
    done
  fi
  [[ -n "$RETAIL" && -e "$RETAIL" ]] || die "Pass --retail /path/to/10.6.3 retail ISO/DMG"
  run_build
  assert_safe_disk
  if (( DRY_RUN == 1 )); then
    cat <<EOF
DRY RUN - no writes performed.
Would erase $DISK as GPT, restore:
  $RETAIL
and install the validated ASUS 1215P IA32 OpenDuet/OpenCore + custom kernel from:
  $BUILD_ROOT
EOF
    return 0
  fi
  printf '\nType exactly: ERASE %s\n> ' "$DISK"
  IFS= read -r answer
  [[ "$answer" == "ERASE $DISK" ]] || die "Confirmation mismatch; nothing erased"
  sudo diskutil partitionDisk "$DISK" GPT JHFS+ INSTALLER R
  efi_slice="${DISK}s1"
  installer_slice="${DISK}s2"
  restore_retail "$RETAIL" "$installer_slice"
  install_efi "$efi_slice"
  log "USB prepared. Verify with: ./legacy_macos_install.sh --target $TARGET --os snowleopard --verify-usb --disk $DISK"
}

run_verify_usb() {
  local efi mp path
  require_macos
  [[ -n "$DISK" ]] || die "--verify-usb requires --disk"
  validate_disk "$DISK"
  diskutil list "$DISK"
  efi="${DISK}s1"
  diskutil mount "$efi" >/dev/null 2>&1 || true
  mp="$(diskutil info "$efi" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}')"
  [[ -d "$mp" ]] || die "EFI is not mounted and could not be mounted"
  for path in boot EFI/BOOT/BOOTIA32.efi EFI/OC/OpenCore.efi EFI/OC/config.plist EFI/OC/Drivers/HfsPlus32.efi Kernels/kernel; do
    if [[ -e "$mp/$path" ]]; then printf 'FOUND   %s\n' "$path"; else printf 'MISSING %s\n' "$path"; fi
  done
  [[ -f "$mp/Kernels/kernel" ]] || die "Custom kernel missing from ESP/Kernels/kernel"
  validate_kernel "$mp/Kernels/kernel" || die "ESP custom kernel is not the expected Darwin 10.3.0 i386 binary"
  plutil -lint "$mp/EFI/OC/config.plist"
  python3 "$CONFIG_PATCHER" --check "$mp/EFI/OC/config.plist"
  printf 'ASUS 1215P config validation: PASS\n'
}

case "$MODE" in
  doctor) run_doctor ;;
  download) run_download ;;
  build) run_build ;;
  list-disks) run_list_disks ;;
  make-usb) run_make_usb ;;
  verify-usb) run_verify_usb ;;
  "") usage; exit 1 ;;
esac
