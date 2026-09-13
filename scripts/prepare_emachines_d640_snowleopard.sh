#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
TARGET_DIR="$ROOT_DIR/targets/emachines-d640-n930"
TARGET_CONF="$TARGET_DIR/target.conf"
KEXT_MANIFEST="$TARGET_DIR/kexts-snowleopard.conf"
CURRENT_SOURCES="$ROOT_DIR/cache/current-sources.env"
MAIN_BUILDER="$ROOT_DIR/prepare_aspire4310_macos.sh"
GENERATOR="$SCRIPT_DIR/generate_target_oc_config.py"
INSPECTOR="$SCRIPT_DIR/inspect_artifact.py"
VALIDATOR="$SCRIPT_DIR/validate_oc_tree.py"
LINUX_USB="$SCRIPT_DIR/linux_make_usb.sh"
COLLECTOR="$SCRIPT_DIR/collect_linux_hardware_v2.sh"

MODE=""
DISK=""
RETAIL=""
AMD_KERNEL=""
KEXT_SET="minimal"
SATA_MODE="native"
BOOT_PRESET="diagnostic"
ACPI_MODE="native"
ALLOW_INTERNAL=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
eMachines D640 / Phenom II N930 Snow Leopard helper

Preparation/build (Linux or macOS):
  ./scripts/prepare_emachines_d640_snowleopard.sh --doctor
  ./scripts/prepare_emachines_d640_snowleopard.sh --download
  ./scripts/prepare_emachines_d640_snowleopard.sh --build
  ./scripts/prepare_emachines_d640_snowleopard.sh --collect-hardware

Linux USB operations:
  ./scripts/prepare_emachines_d640_snowleopard.sh --list-disks
  sudo ./scripts/prepare_emachines_d640_snowleopard.sh --make-usb \
    --disk /dev/sdX --retail /path/to/SnowLeopard-Retail.iso \
    --amd-kernel /path/to/legacy_amd_mach_kernel
  sudo ./scripts/prepare_emachines_d640_snowleopard.sh --verify --disk /dev/sdX
  sudo ./scripts/prepare_emachines_d640_snowleopard.sh --update-efi --disk /dev/sdX

Build options:
  --kext-set smc|minimal|full      default: minimal
  --sata native|injected           default: native
  --acpi native|patched            patched reads input/targets/emachines-d640-n930/acpi/*.aml
  --boot-preset normal|verbose|safe|diagnostic

Important: this target requires a user-supplied Snow Leopard AMD K10 kernel for
real hardware. The EFI build itself is allowed without one so it can be audited.
USAGE
}

log() { printf '[d640] %s\n' "$*"; }
warn() { printf '[d640] WARNING: %s\n' "$*" >&2; }
die() { printf '[d640] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
set_mode() { [[ -z "$MODE" || "$MODE" == "$1" ]] || die "Choose one operation"; MODE="$1"; }
need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }

while (($#)); do
  case "$1" in
    --doctor) set_mode doctor ;;
    --download) set_mode download ;;
    --build) set_mode build ;;
    --collect-hardware) set_mode collect-hardware ;;
    --list-disks) set_mode list-disks ;;
    --make-usb) set_mode make-usb ;;
    --update-efi) set_mode update-efi ;;
    --verify) set_mode verify ;;
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --retail) need_value "$@"; shift; RETAIL="$1" ;;
    --amd-kernel) need_value "$@"; shift; AMD_KERNEL="$1" ;;
    --kext-set) need_value "$@"; shift; KEXT_SET="$1" ;;
    --sata) need_value "$@"; shift; SATA_MODE="$1" ;;
    --acpi) need_value "$@"; shift; ACPI_MODE="$1" ;;
    --boot-preset) need_value "$@"; shift; BOOT_PRESET="$1" ;;
    --allow-internal) ALLOW_INTERNAL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

case "$KEXT_SET" in smc|minimal|full) ;; *) die "Invalid --kext-set" ;; esac
case "$SATA_MODE" in native|injected) ;; *) die "Invalid --sata" ;; esac
case "$ACPI_MODE" in native|patched) ;; *) die "Invalid --acpi" ;; esac
case "$BOOT_PRESET" in normal|verbose|safe|diagnostic) ;; *) die "Invalid --boot-preset" ;; esac

[[ -f "$TARGET_CONF" ]] || die "Missing target profile: $TARGET_CONF"
# shellcheck disable=SC1090
source "$TARGET_CONF"

BUILD_ROOT="$ROOT_DIR/output/targets/$TARGET_ID/snowleopard/opencore"
INPUT_TARGET="$ROOT_DIR/input/targets/$TARGET_ID"

load_sources() {
  [[ -f "$CURRENT_SOURCES" ]] || die "Assets are not prepared. Run --download first."
  # shellcheck disable=SC1090
  source "$CURRENT_SOURCES"
  OC_CACHE_ROOT="$ROOT_DIR/cache/$OC_CACHE_REL"
  LEGACY_KEXTS_ROOT="$ROOT_DIR/cache/$LEGACY_KEXTS_CACHE_REL"
  [[ -f "$OC_CACHE_ROOT/Docs/Sample.plist" ]] || die "OpenCore cache incomplete: $OC_CACHE_ROOT"
  [[ -d "$LEGACY_KEXTS_ROOT/FAT" ]] || die "Legacy-Kexts cache incomplete: $LEGACY_KEXTS_ROOT"
}

run_doctor() {
  printf 'Target: %s\nCPU: %s (%s)\nGPU: %s [%s]\nFirmware: %s\n' \
    "$TARGET_MODEL" "$TARGET_CPU" "$TARGET_CPU_CPUID" "$TARGET_GPU" "$TARGET_GPU_PCI" "$TARGET_FIRMWARE"
  printf 'Required target kernel: custom AMD K10 Snow Leopard kernel (%s)\n' "$TARGET_KERNEL_ARCH"
  printf 'Build host: %s %s\n' "$(uname -s)" "$(uname -m)"
  printf '\nBuild tools:\n'
  local cmd missing=0
  for cmd in bash python3 curl unzip file; do
    if have "$cmd"; then printf '  OK      %s\n' "$cmd"; else printf '  MISSING %s\n' "$cmd"; missing=1; fi
  done
  printf '\nLinux USB tools (required only for --make-usb):\n'
  for cmd in lsblk findmnt losetup sgdisk mkfs.vfat mkfs.hfsplus rsync fdisk uuidgen; do
    if have "$cmd"; then printf '  OK/WARN %s\n' "$cmd"; else printf '  MISSING %s\n' "$cmd"; fi
  done
  [[ -f "$CURRENT_SOURCES" ]] && printf '\nCached OpenCore sources: PRESENT\n' || printf '\nCached OpenCore sources: NOT PREPARED\n'
  return "$missing"
}

copy_tree() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  cp -a "$src"/. "$dst"/
}

copy_target_kexts() {
  local destination="$1" set_name source_path status purpose source target
  while IFS=$'\t' read -r set_name source_path status purpose; do
    [[ -n "$set_name" && "$set_name" != \#* ]] || continue
    case "$set_name" in
      smc) ;;
      minimal) [[ "$KEXT_SET" != smc ]] || continue ;;
      full) [[ "$KEXT_SET" == full ]] || continue ;;
      sata) [[ "$SATA_MODE" == injected ]] || continue ;;
      *) continue ;;
    esac
    source="$LEGACY_KEXTS_ROOT/$source_path"
    [[ -d "$source" ]] || die "Kext from manifest not found: $source"
    target="$destination/$(basename "$source")"
    [[ ! -e "$target" ]] || die "Kext basename collision: $target"
    copy_tree "$source" "$target"
    python3 "$INSPECTOR" --kext "$target" --quiet >/dev/null
    if python3 - "$target/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f: p=plistlib.load(f)
raise SystemExit(0 if p.get('CFBundleExecutable') else 1)
PY
    then
      python3 "$INSPECTOR" --kext "$target" --require-arch i386 --quiet
    fi
    log "Enabled $(basename "$target") [$status] — $purpose"
  done < "$KEXT_MANIFEST"
}

collect_kext_args() {
  find "$1/Kexts" -type d -name '*.kext' -print | sed "s#^$1/Kexts/##" | LC_ALL=C sort
}

run_build() {
  load_sources
  local ia32="$OC_CACHE_ROOT/IA32"
  local oc="$BUILD_ROOT/ESP/EFI/OC"
  local esp="$BUILD_ROOT/ESP"
  local relative item hfs32 validator
  local -a args

  [[ -f "$ia32/EFI/OC/OpenCore.efi" ]] || die "This OpenCore release/cache has no IA32 OpenCore binary: $ia32"
  [[ -f "$ia32/EFI/BOOT/BOOTIA32.efi" ]] || die "Missing IA32 BOOTIA32.efi"
  hfs32="$ROOT_DIR/downloads/$HFS_32_FILE"
  [[ -f "$hfs32" ]] || die "Missing pinned HfsPlus32.efi: $hfs32"

  rm -rf -- "$BUILD_ROOT"
  mkdir -p "$esp/EFI/BOOT" "$oc/ACPI" "$oc/Drivers" "$oc/Kexts" "$oc/Tools" "$BUILD_ROOT/OpenDuet"
  cp -a "$ia32/EFI/BOOT/BOOTIA32.efi" "$esp/EFI/BOOT/BOOTIA32.efi"
  cp -a "$ia32/EFI/OC/OpenCore.efi" "$oc/OpenCore.efi"
  cp -a "$ia32/EFI/OC/Drivers/Ps2KeyboardDxe.efi" "$oc/Drivers/Ps2KeyboardDxe.efi"
  cp -a "$ia32/EFI/OC/Drivers/Ps2MouseDxe.efi" "$oc/Drivers/Ps2MouseDxe.efi"
  cp -a "$hfs32" "$oc/Drivers/HfsPlus32.efi"
  cp -a "$OC_CACHE_ROOT/Utilities/LegacyBoot/bootIA32" "$esp/boot"

  for item in BootInstall_IA32.tool BootInstallBase.sh boot0 boot1f32 bootIA32 README.md; do
    cp -a "$OC_CACHE_ROOT/Utilities/LegacyBoot/$item" "$BUILD_ROOT/OpenDuet/$item"
  done

  copy_target_kexts "$oc/Kexts"

  args=(
    --sample "$OC_CACHE_ROOT/Docs/Sample.plist"
    --output "$oc/config.plist"
    --oc-root "$oc"
    --os snowleopard
    --target-name "$TARGET_MODEL"
    --smbios "$TARGET_SMBIOS"
    --rom-ascii "$TARGET_ROM_ASCII"
    --serial "$TARGET_SERIAL"
    --mlb "$TARGET_MLB"
    --uuid-seed "$TARGET_UUID_SEED"
    --kernel-arch i386
    --kernel-cache Cacheless
    --boot-preset "$BOOT_PRESET"
    --runtime-profile off
    --driver HfsPlus32.efi
    --driver Ps2KeyboardDxe.efi
    --driver Ps2MouseDxe.efi
    --oc-version "$OC_VERSION"
  )

  while IFS= read -r relative; do
    [[ -n "$relative" ]] && args+=(--kext "$relative")
  done < <(collect_kext_args "$oc")

  if [[ "$ACPI_MODE" == patched ]]; then
    mkdir -p "$INPUT_TARGET/acpi"
    shopt -s nullglob
    for item in "$INPUT_TARGET"/acpi/*.aml; do
      cp -a "$item" "$oc/ACPI/$(basename "$item")"
      args+=(--acpi "$(basename "$item")")
    done
    shopt -u nullglob
    [[ -n "$(find "$oc/ACPI" -maxdepth 1 -type f -name '*.aml' -print -quit)" ]] \
      || die "--acpi patched requested but $INPUT_TARGET/acpi has no AML tables"
  fi

  python3 "$GENERATOR" "${args[@]}"
  python3 "$VALIDATOR" "$oc/config.plist"

  validator="$OC_CACHE_ROOT/Utilities/ocvalidate/ocvalidate.linux"
  if [[ "$(uname -s)" == Darwin ]]; then validator="$OC_CACHE_ROOT/Utilities/ocvalidate/ocvalidate"; fi
  if [[ -f "$validator" ]]; then
    chmod +x "$validator" 2>/dev/null || true
    "$validator" "$oc/config.plist"
  else
    warn "ocvalidate binary for this host was not found; tree validator still passed"
  fi

  mkdir -p "$BUILD_ROOT/Payload"
  if [[ -n "$AMD_KERNEL" ]]; then
    [[ -f "$AMD_KERNEL" ]] || die "AMD kernel not found: $AMD_KERNEL"
    python3 "$INSPECTOR" --binary "$AMD_KERNEL" --require-arch i386 --quiet \
      || die "Supplied AMD kernel does not expose a confirmed i386 Mach-O slice"
    cp -a "$AMD_KERNEL" "$BUILD_ROOT/Payload/mach_kernel"
    sha256sum "$BUILD_ROOT/Payload/mach_kernel" > "$BUILD_ROOT/Payload/mach_kernel.sha256"
  fi

  cat > "$BUILD_ROOT/BUILD_REPORT.md" <<REPORT
# eMachines D640 Snow Leopard build

- Target: $TARGET_MODEL
- CPU: $TARGET_CPU / $TARGET_CPU_CPUID
- Architecture: IA32 OpenDuet + i386 Snow Leopard kernel path
- Kernel cache mode: Cacheless (force direct /mach_kernel bring-up)
- GPU: $TARGET_GPU ($TARGET_GPU_PCI)
- OpenCore: $OC_VERSION $OC_VARIANT
- SMBIOS bring-up identity: $TARGET_SMBIOS
- Kext set: $KEXT_SET
- SATA mode: $SATA_MODE
- ACPI mode: $ACPI_MODE
- Boot preset: $BOOT_PRESET
- AMD kernel bundled in Payload: $([[ -f "$BUILD_ROOT/Payload/mach_kernel" ]] && printf YES || printf NO)

The profile does not auto-patch HD 5470 connectors, AR9285 Wi-Fi, ALC272 AppleHDA,
or DSDT. Those remain gated on the physical Linux hardware dump.
REPORT
  log "Build complete: $BUILD_ROOT"
}

case "$MODE" in
  doctor) run_doctor ;;
  download)
    "$MAIN_BUILDER" --download
    ;;
  build)
    run_build
    ;;
  collect-hardware)
    "$COLLECTOR" "$ROOT_DIR/input/hardware"
    ;;
  list-disks)
    "$LINUX_USB" --list-disks
    ;;
  make-usb)
    [[ -n "$DISK" && -n "$RETAIL" && -n "$AMD_KERNEL" ]] \
      || die "--make-usb requires --disk, --retail and --amd-kernel"
    run_build
    usb_args=(--make-usb --disk "$DISK" --retail "$RETAIL" --build-root "$BUILD_ROOT" --amd-kernel "$AMD_KERNEL")
    (( ALLOW_INTERNAL == 1 )) && usb_args+=(--allow-internal)
    (( DRY_RUN == 1 )) && usb_args+=(--dry-run)
    "$LINUX_USB" "${usb_args[@]}"
    ;;
  update-efi)
    [[ -n "$DISK" ]] || die "--update-efi requires --disk"
    run_build
    usb_args=(--update-efi --disk "$DISK" --build-root "$BUILD_ROOT")
    (( ALLOW_INTERNAL == 1 )) && usb_args+=(--allow-internal)
    (( DRY_RUN == 1 )) && usb_args+=(--dry-run)
    "$LINUX_USB" "${usb_args[@]}"
    ;;
  verify)
    [[ -n "$DISK" ]] || die "--verify requires --disk"
    "$LINUX_USB" --verify --disk "$DISK"
    ;;
  "") usage; exit 2 ;;
  *) die "Unexpected mode: $MODE" ;;
esac
