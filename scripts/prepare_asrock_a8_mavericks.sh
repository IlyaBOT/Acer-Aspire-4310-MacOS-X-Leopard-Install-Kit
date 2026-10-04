#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET="asrock-fm2a58m-vg3-a8-7600"
PROFILE_DIR="$ROOT_DIR/profiles/$TARGET/mavericks"
HARDWARE_CONF="$ROOT_DIR/profiles/$TARGET/hardware.conf"
PROFILE_CONF="$PROFILE_DIR/profile.conf"
KEXT_MANIFEST="$PROFILE_DIR/kexts.conf"
CURRENT_SOURCES="$ROOT_DIR/cache/current-sources.env"
COMMON_ASSET_ENGINE="$ROOT_DIR/prepare_aspire4310_macos.sh"
ASSET_DOWNLOADER="$ROOT_DIR/scripts/download_a8_mavericks_assets.sh"
OC_BUILDER="$ROOT_DIR/scripts/build_carnations_opencore.sh"
GENERATOR="$ROOT_DIR/scripts/generate_target_oc_config.py"
VALIDATOR="$ROOT_DIR/scripts/validate_oc_tree.py"
KERNEL_INSTALLER="$ROOT_DIR/scripts/apply_mavericks_amd_kernel.sh"
RECOVERY_USB_WRITER="$ROOT_DIR/scripts/linux_make_recovery_usb.sh"
CACHE_ROOT="$ROOT_DIR/cache/a8-7600-mavericks"
OUTPUT_ROOT="$ROOT_DIR/output/targets/$TARGET/mavericks"
BUILD_ROOT="$OUTPUT_ROOT/opencore-custom"

MODE=""
KEXT_SET="minimal"
BOOT_PRESET="verbose"
OPENCOR_ARCHIVE=""
VOLUME=""
DISK=""
ASSUME_YES=0
ALLOW_INTERNAL=0

# shellcheck disable=SC1090
source "$HARDWARE_CONF"
# shellcheck disable=SC1090
source "$PROFILE_CONF"

log() { printf '[a8-mavericks] %s\n' "$*"; }
warn() { printf '[a8-mavericks] WARNING: %s\n' "$*" >&2; }
die() { printf '[a8-mavericks] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }

usage() {
  cat <<'EOF'
ASRock FM2A58M-VG3+ R2.0 / AMD A8-7600 / Mavericks bring-up.

Read-only:
  ./scripts/prepare_asrock_a8_mavericks.sh --doctor

Fetch pinned kernel/patch/kext sources:
  ./scripts/prepare_asrock_a8_mavericks.sh --download

Build the X64 UEFI OpenCore tree:
  ./scripts/prepare_asrock_a8_mavericks.sh --build
  ./scripts/prepare_asrock_a8_mavericks.sh --build --kext-set full

The repository-bundled Carnations OpenCore 1.0.5 DEBUG archive is preferred
automatically. --opencore-archive remains available for an explicit override.

Create a fresh UEFI Mavericks Recovery USB on Linux (DESTRUCTIVE). This copies
OpenCore + the custom AMD kernel and downloads RecoveryImage.dmg/chunklist with
the bundled macrecovery.py:
  sudo ./scripts/prepare_asrock_a8_mavericks.sh --make-usb --disk /dev/sdX

Apply the required DEBUG Mavericks kernel to a writable installer/system root:
  sudo ./scripts/prepare_asrock_a8_mavericks.sh --apply-kernel --volume /mnt/Mavericks

Options:
  --kext-set minimal|full       minimal: FakeSMC + NullCPUPM + TSC sync + Ethernet
                                full also adds VoodooHDA and EvOreboot
  --boot-preset normal|verbose|safe|diagnostic
  --opencore-archive PATH       override the repository-bundled Carnations archive
  --disk /dev/sdX               whole USB disk for --make-usb
  --yes                         skip destructive USB confirmation
  --allow-internal              allow --make-usb on a disk not marked removable

The build is experimental. Only --make-usb writes a disk, and it is destructive.
EOF
}

while (($#)); do
  case "$1" in
    --doctor) MODE=doctor ;;
    --download|--download-only) MODE=download ;;
    --build) MODE=build ;;
    --apply-kernel) MODE=apply-kernel ;;
    --make-usb) MODE=make-usb ;;
    --kext-set) need_value "$@"; shift; KEXT_SET="$1" ;;
    --boot-preset) need_value "$@"; shift; BOOT_PRESET="$1" ;;
    --opencore-archive) need_value "$@"; shift; OPENCOR_ARCHIVE="$1" ;;
    --volume) need_value "$@"; shift; VOLUME="$1" ;;
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --yes) ASSUME_YES=1 ;;
    --allow-internal) ALLOW_INTERNAL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

case "$KEXT_SET" in minimal|full) ;; *) die "--kext-set must be minimal or full" ;; esac
case "$BOOT_PRESET" in normal|verbose|safe|diagnostic) ;; *) die "invalid --boot-preset" ;; esac

load_shared_sources() {
  [[ -f "$CURRENT_SOURCES" ]] || die "Shared cache is not prepared; run --download"
  # shellcheck disable=SC1090
  source "$CURRENT_SOURCES"
  LEGACY_KEXTS_ROOT="$ROOT_DIR/cache/$LEGACY_KEXTS_CACHE_REL"
  [[ -d "$LEGACY_KEXTS_ROOT/FAT" ]] || die "Legacy-Kexts cache is incomplete: $LEGACY_KEXTS_ROOT"
}

run_doctor() {
  local failures=0 cmd
  printf 'Target: %s\n' "$TARGET_MODEL"
  printf 'Board: %s\n' "$TARGET_BOARD"
  printf 'CPU: %s (%s cores / %s threads, family %s model %s stepping %s)\n'     "$TARGET_CPU" "$TARGET_CPU_CORES" "$TARGET_CPU_THREADS" "$TARGET_CPU_FAMILY" "$TARGET_CPU_MODEL_NUMBER" "$TARGET_CPU_STEPPING"
  printf 'GPU first boot: %s\n' "$TARGET_GPU_FIRST_BOOT"
  printf 'Ethernet: %s\n' "$TARGET_ETHERNET"
  printf 'OS: %s %s / Darwin %s\n' "$OS_NAME" "$OS_FINAL" "$DARWIN_RANGE"
  printf 'Kernel: x86_64 DEBUG + Carnations Botanica Mavericks patch set\n'
  printf 'OpenCore: pinned Carnations Botanica royalDevelopment %s\n' "$TARGET_OPENCORE_SOURCE_COMMIT"
  printf 'Status: %s\n\n' "$PROFILE_STATUS"

  printf 'Host tools:\n'
  for cmd in bash curl python3 git docker unzip file; do
    if have "$cmd"; then
      printf '  OK      %-10s %s\n' "$cmd" "$(command -v "$cmd")"
    else
      case "$cmd" in
        docker)
          printf '  WARN    %-10s missing; only the source-build fallback needs Docker\n' "$cmd"
          ;;
        unzip|file)
          printf '  WARN    %-10s optional quality/inspection tool missing\n' "$cmd"
          ;;
        *)
          printf '  MISSING %s\n' "$cmd"
          failures=$((failures+1))
          ;;
      esac
    fi
  done

  printf '\nCaches:\n'
  [[ -f "$CACHE_ROOT/amd/10-9-Mavericks-DEBUG.plist" ]] && printf '  OK      AMD patch plist\n' || printf '  WARN    AMD patch plist not downloaded\n'
  [[ -f "$CACHE_ROOT/amd/mach_kernel" ]] && printf '  OK      Mavericks DEBUG mach_kernel\n' || printf '  WARN    Mavericks DEBUG mach_kernel not downloaded\n'
  [[ -d "$CACHE_ROOT/kexts/RealtekRTL8111.kext" ]] && printf '  OK      RealtekRTL8111 1.2.3\n' || printf '  WARN    RealtekRTL8111 1.2.3 not downloaded\n'

  if bash "$OC_BUILDER" --print-root >/dev/null 2>&1; then
    printf '  OK      modified Carnations OpenCore cache\n'
  elif [[ -f "$ROOT_DIR/vendor/carnations-opencore/OpenCore-1.0.5-DEBUG.zip" ]]; then
    printf '  OK      repository-bundled Carnations OpenCore 1.0.5 DEBUG\n'
  else
    printf '  WARN    bundled Carnations OpenCore archive is missing; Docker fallback would be required\n'
  fi

  printf '\nRequired profile facts:\n'
  printf '  ProvideCurrentCpuInfo=YES\n'
  printf '  FixupAppleEfiImages=YES\n'
  printf '  cpuid_cores_per_package=%s physical cores\n' "$TARGET_AMD_PATCH_CORES"
  printf '  VoodooTSCSync IOCPUNumber=%s\n' "$((TARGET_AMD_PATCH_CORES-1))"
  printf '  KernelCache=Cacheless for first bring-up\n'
  printf '  SMBIOS=%s\n' "$TARGET_SMBIOS"
  printf '  Kaveri iGPU blacklist=%s at %s (%s)\n' \
    "$TARGET_GPU_INTEGRATED_BLACKLIST" "$TARGET_GPU_INTEGRATED_OC_PATH" "$TARGET_GPU_INTEGRATED_BDF"
  warn "The exact onboard HDA codec was not present in the uploaded audit; VoodooHDA is therefore full-set/experimental."
  warn "The BIOS still exposes Kaveri 1002:1313 as PCI 00:01.0, so the generated config additionally poisons its macOS PCI match properties."
  (( failures == 0 ))
}

run_download() {
  log "Preparing shared OcBinaryData/Legacy-Kexts cache"
  bash "$COMMON_ASSET_ENGINE" --download --skip-combo-updates
  log "Downloading pinned AMD Mavericks patch plist, DEBUG kernel and legacy RTL8111 kext"
  bash "$ASSET_DOWNLOADER"
  if [[ -n "$OPENCOR_ARCHIVE" ]]; then
    bash "$OC_BUILDER" --archive "$OPENCOR_ARCHIVE" >/dev/null
  fi
}

want_manifest_row() {
  local set="$1"
  case "$set:$KEXT_SET" in
    required:*) return 0 ;;
    minimal:minimal|minimal:full) return 0 ;;
    full:full) return 0 ;;
  esac
  return 1
}

copy_kexts() {
  local oc_root="$1" set source path status purpose src dest
  KEXT_ARGS=()
  while IFS=$'\t' read -r set source path status purpose; do
    [[ -n "$set" && "$set" != \#* ]] || continue
    want_manifest_row "$set" || continue

    case "$source" in
      legacy) src="$LEGACY_KEXTS_ROOT/$path" ;;
      external) src="$CACHE_ROOT/kexts/$path" ;;
      *) die "Unknown kext source '$source' in $KEXT_MANIFEST" ;;
    esac
    [[ -d "$src" ]] || die "Required kext is missing: $src"
    dest="$oc_root/Kexts/$(basename "$path")"
    rm -rf -- "$dest"
    cp -R -- "$src" "$dest"
    KEXT_ARGS+=(--kext "$(basename "$path")")
    log "Kext: $(basename "$path") [$status] $purpose"
  done < "$KEXT_MANIFEST"

  local tsc="$oc_root/Kexts/VoodooTSCSync.kext/Contents/Info.plist"
  [[ -f "$tsc" ]] || die "VoodooTSCSync Info.plist is missing"
  python3 - "$tsc" "$TARGET_AMD_PATCH_CORES" <<'PY'
import plistlib,sys
path=sys.argv[1]
cores=int(sys.argv[2])
with open(path,"rb") as f:
    p=plistlib.load(f)
node=p["IOKitPersonalities"]["VoodooTSCSync"]["IOPropertyMatch"]
node["IOCPUNumber"]=cores-1
with open(path,"wb") as f:
    plistlib.dump(p,f,fmt=plistlib.FMT_XML,sort_keys=False)
print(f"VoodooTSCSync IOCPUNumber={cores-1}")
PY
}

validate_kext_arches() {
  local root="$1" plist executable binary result
  have file || { warn "file(1) missing; skipping kext Mach-O architecture check"; return 0; }
  while IFS= read -r -d '' plist; do
    executable="$(python3 - "$plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],"rb") as f: p=plistlib.load(f)
print(p.get("CFBundleExecutable",""))
PY
)"
    [[ -n "$executable" ]] || continue
    binary="$(dirname "$plist")/MacOS/$executable"
    [[ -f "$binary" ]] || die "Missing kext executable: $binary"
    result="$(file "$binary")"
    [[ "$result" == *x86_64* ]] || die "Kext lacks x86_64 slice: $result"
  done < <(find "$root/Kexts" -name Info.plist -print0)
}

run_build() {
  [[ -f "$CURRENT_SOURCES" && -f "$CACHE_ROOT/amd/mach_kernel" ]] || run_download
  load_shared_sources

  local oc_dist
  if [[ -n "$OPENCOR_ARCHIVE" ]]; then
    bash "$OC_BUILDER" --archive "$OPENCOR_ARCHIVE" >/dev/null
  fi
  oc_dist="$(bash "$OC_BUILDER" --ensure | tail -n1)"
  [[ -d "$oc_dist" ]] || die "Modified OpenCore cache not found: $oc_dist"

  rm -rf -- "$BUILD_ROOT"
  mkdir -p "$BUILD_ROOT/ESP/EFI/BOOT" \
           "$BUILD_ROOT/ESP/EFI/OC/Drivers" \
           "$BUILD_ROOT/ESP/EFI/OC/Kexts" \
           "$BUILD_ROOT/ESP/Kernels" \
           "$BUILD_ROOT/Payload"

  cp -f "$oc_dist/X64/EFI/BOOT/BOOTx64.efi" "$BUILD_ROOT/ESP/EFI/BOOT/BOOTX64.efi"
  cp -f "$oc_dist/X64/EFI/OC/OpenCore.efi" "$BUILD_ROOT/ESP/EFI/OC/OpenCore.efi"

  [[ -f "$oc_dist/X64/EFI/OC/Drivers/OpenRuntime.efi" ]] || die "Modified OpenCore archive is missing OpenRuntime.efi"
  [[ -f "$oc_dist/X64/EFI/OC/Drivers/OpenHfsPlus.efi" ]] || die "Modified OpenCore archive is missing OpenHfsPlus.efi"
  [[ -f "$oc_dist/X64/EFI/OC/Drivers/OpenPartitionDxe.efi" ]] || die "Modified OpenCore archive is missing OpenPartitionDxe.efi"
  cp -f "$oc_dist/X64/EFI/OC/Drivers/OpenRuntime.efi" "$BUILD_ROOT/ESP/EFI/OC/Drivers/OpenRuntime.efi"
  cp -f "$oc_dist/X64/EFI/OC/Drivers/OpenHfsPlus.efi" "$BUILD_ROOT/ESP/EFI/OC/Drivers/OpenHfsPlus.efi"
  cp -f "$oc_dist/X64/EFI/OC/Drivers/OpenPartitionDxe.efi" "$BUILD_ROOT/ESP/EFI/OC/Drivers/OpenPartitionDxe.efi"

  copy_kexts "$BUILD_ROOT/ESP/EFI/OC"
  validate_kext_arches "$BUILD_ROOT/ESP/EFI/OC"

  local generator_args=(
    --sample "$oc_dist/Docs/Sample.plist"
    --output "$BUILD_ROOT/ESP/EFI/OC/config.plist"
    --oc-root "$BUILD_ROOT/ESP/EFI/OC"
    --os mavericks
    --target-name "$TARGET_MODEL"
    --smbios "$TARGET_SMBIOS"
    --rom-ascii "$TARGET_ROM_ASCII"
    --serial "$TARGET_SERIAL"
    --mlb "$TARGET_MLB"
    --uuid-seed "$TARGET_UUID_SEED"
    --kernel-arch x86_64
    --kernel-cache Cacheless
    --boot-preset "$BOOT_PRESET"
    --runtime-profile legacy
    --setup-virtual-map
    --force-exit-boot-services
    --custom-kernel
    --provide-current-cpu-info
    --no-release-usb-ownership
    --blacklist-gpu-pci-path "$TARGET_GPU_INTEGRATED_OC_PATH"
    --driver OpenHfsPlus.efi
    --driver OpenPartitionDxe.efi
    --driver OpenRuntime.efi
    --kernel-patches-plist "$CACHE_ROOT/amd/10-9-Mavericks-DEBUG.plist"
    --amd-core-count "$TARGET_AMD_PATCH_CORES"
  )
  generator_args+=("${KEXT_ARGS[@]}")

  python3 "$GENERATOR" "${generator_args[@]}"

  # CustomKernel validation checks the finished ESP tree, so stage the AMD
  # mach_kernel before validate_oc_tree.py runs.
  cp -f "$CACHE_ROOT/amd/mach_kernel" "$BUILD_ROOT/Payload/mach_kernel"
  cp -f "$CACHE_ROOT/amd/mach_kernel" "$BUILD_ROOT/ESP/Kernels/mach_kernel"
  chmod 0644 "$BUILD_ROOT/Payload/mach_kernel" "$BUILD_ROOT/ESP/Kernels/mach_kernel"

  python3 "$VALIDATOR" "$BUILD_ROOT/ESP/EFI/OC/config.plist"

  cp -f "$CACHE_ROOT/amd/10-9-Mavericks-DEBUG.plist" "$BUILD_ROOT/Payload/10-9-Mavericks.source.plist"
  cp -f "$KERNEL_INSTALLER" "$BUILD_ROOT/Payload/apply_mavericks_amd_kernel.sh"
  chmod 0755 "$BUILD_ROOT/Payload/apply_mavericks_amd_kernel.sh"

  python3 - "$BUILD_ROOT/ESP/EFI/OC/config.plist" "$TARGET_AMD_PATCH_CORES" <<'PY'
import plistlib,sys
path=sys.argv[1]
cores=int(sys.argv[2])
with open(path,"rb") as f: c=plistlib.load(f)
assert c["Booter"]["Quirks"]["FixupAppleEfiImages"] is True
assert c["Kernel"]["Quirks"]["ProvideCurrentCpuInfo"] is True
assert c["Kernel"]["Emulate"]["DummyPowerManagement"] is True
assert c["Kernel"]["Scheme"]["CustomKernel"] is True
assert c["Kernel"]["Scheme"]["KernelArch"] == "x86_64"
assert c["Kernel"]["Scheme"]["KernelCache"] == "Cacheless"
assert c["Booter"]["Quirks"]["EnableWriteUnprotector"] is True
assert c["Booter"]["Quirks"]["RebuildAppleMemoryMap"] is False
assert c["Booter"]["Quirks"]["SyncRuntimePermissions"] is False
assert c["Booter"]["Quirks"]["SetupVirtualMap"] is True
assert c["Booter"]["Quirks"]["ForceExitBootServices"] is True
assert c["UEFI"]["Quirks"]["ReleaseUsbOwnership"] is False
drivers={d["Path"] for d in c["UEFI"]["Drivers"] if d.get("Enabled")}
assert "OpenHfsPlus.efi" in drivers
assert "OpenPartitionDxe.efi" in drivers
assert "HfsPlusLegacy.efi" not in drivers
assert "OpenRuntime.efi" in drivers
igpu=c["DeviceProperties"]["Add"]["PciRoot(0x0)/Pci(0x1,0x0)"]
assert igpu["name"] == "unused"
assert igpu["IOName"] == "#display"
assert igpu["class-code"] == b"\xff\xff\xff\xff"
assert igpu["vendor-id"] == b"\xff\xff\x00\x00"
assert igpu["device-id"] == b"\xff\xff\x00\x00"
patches=c["Kernel"]["Patch"]
assert len(patches) >= 10
core=[p for p in patches if "cpuid_cores_per_package" in p.get("Comment","")]
assert len(core)==1
assert core[0]["Replace"] == b"\xba"+bytes([cores])+b"\x00\x00\x00"
bundles={k["BundlePath"] for k in c["Kernel"]["Add"] if k.get("Enabled")}
for required in ("fakesmc.kext","NullCPUPowerManagement.kext","VoodooTSCSync.kext","RealtekRTL8111.kext"):
    assert required in bundles, required
assert c["PlatformInfo"]["Generic"]["SystemProductName"] == "MacPro3,1"
print(f"A8 Mavericks config validation: PASS ({len(patches)} AMD kernel patches, cores={cores})")
PY

  cat > "$BUILD_ROOT/Payload/README.txt" <<EOF
ASRock FM2A58M-VG3+ R2.0 / AMD A8-7600 Mavericks experimental UEFI payload

1. UEFI boot tree:
   ESP/EFI/
   ESP/Kernels/mach_kernel

2. Boot firmware entry:
   UEFI: <USB name>
   OpenDuet/legacy BIOS is not used by this target's normal path.

3. Recovery DMG drivers:
   OpenHfsPlus.efi
   OpenPartitionDxe.efi (Mavericks RecoveryImage.dmg uses Apple Partition Map)
   HfsPlusLegacy.efi is intentionally not used.

4. Kernel scheme:
   CustomKernel=YES
   KernelArch=x86_64
   KernelCache=Cacheless

5. The Carnations Botanica Mavericks patch set is merged into config.plist.
   cpuid_cores_per_package is specialized for 4 physical cores.

6. UEFI memory/profile quirks:
   ReleaseUsbOwnership=NO
   EnableWriteUnprotector=YES
   RebuildAppleMemoryMap=NO
   SyncRuntimePermissions=NO
   SetupVirtualMap=YES
   ForceExitBootServices=YES

7. VoodooTSCSync IOCPUNumber=3 for the 4-core A8-7600.

8. The Kaveri Radeon R7 iGPU (1002:1313, PCI 00:01.0) is blacklisted at
   PciRoot(0x0)/Pci(0x1,0x0). The discrete Turks XT 1002:6758 remains untouched.

9. Create the complete Recovery USB with:
   sudo ./legacy_macos_install.sh --target $TARGET --os mavericks --make-usb --disk /dev/sdX
EOF

  log "Build complete: $BUILD_ROOT"
  log "UEFI: $BUILD_ROOT/ESP/EFI"
  log "Custom kernel: $BUILD_ROOT/ESP/Kernels/mach_kernel"
}

run_make_usb() {
  [[ -n "$DISK" ]] || die "--make-usb requires --disk /dev/sdX"
  [[ -f "$BUILD_ROOT/ESP/EFI/OC/config.plist" ]] || die "Build is missing; run --build first"
  [[ -f "$RECOVERY_USB_WRITER" ]] || die "Recovery USB writer is missing: $RECOVERY_USB_WRITER"

  local oc_dist
  oc_dist="$(bash "$OC_BUILDER" --ensure | tail -n1)"
  [[ -f "$oc_dist/Utilities/macrecovery/macrecovery.py" ]] || die "macrecovery.py missing from pinned OpenCore distribution"

  local args=(
    --make-usb
    --disk "$DISK"
    --build-root "$BUILD_ROOT"
    --macrecovery "$oc_dist/Utilities/macrecovery/macrecovery.py"
  )
  (( ASSUME_YES == 1 )) && args+=(--yes)
  (( ALLOW_INTERNAL == 1 )) && args+=(--allow-internal)

  exec bash "$RECOVERY_USB_WRITER" "${args[@]}"
}

case "$MODE" in
  doctor) run_doctor ;;
  download) run_download ;;
  build) run_build ;;
  apply-kernel)
    [[ -n "$VOLUME" ]] || die "--apply-kernel requires --volume"
    [[ -f "$CACHE_ROOT/amd/mach_kernel" ]] || bash "$ASSET_DOWNLOADER"
    exec bash "$KERNEL_INSTALLER" --volume "$VOLUME" --kernel "$CACHE_ROOT/amd/mach_kernel"
    ;;
  make-usb) run_make_usb ;;
  "") usage; exit 2 ;;
esac
