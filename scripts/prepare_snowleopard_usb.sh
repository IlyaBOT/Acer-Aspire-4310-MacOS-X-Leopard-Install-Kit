#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MAIN="$SCRIPT_DIR/../prepare_aspire4310_macos.sh"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

MODE=""
EXPERIMENTAL_X64=0
DISK=""
RETAIL=""

usage() {
  cat <<'EOF'
Snow Leopard convenience wrapper for Acer Aspire 4310

Recommended GMA950-safe path (default):
  ./scripts/prepare_snowleopard_usb.sh --download
  ./scripts/prepare_snowleopard_usb.sh --build
  ./scripts/prepare_snowleopard_usb.sh --list-disks
  ./scripts/prepare_snowleopard_usb.sh --make-usb --disk /dev/diskX \
    --retail input/SnowLeopard-Retail.iso
  ./scripts/prepare_snowleopard_usb.sh --verify --disk /dev/diskX

Experimental 64-bit-kernel path:
  ./scripts/prepare_snowleopard_usb.sh --build --x64
  ./scripts/prepare_snowleopard_usb.sh --make-usb --x64 --disk /dev/diskX \
    --retail input/SnowLeopard-Retail.iso

The x64 mode is intentionally experimental on GMA950. The default uses an i386
Snow Leopard kernel with IA32 OpenDuet/OpenCore, while retaining Snow Leopard's
ability to run 64-bit userland where the OS/application permits it.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

set_mode() {
  [[ -z "$MODE" || "$MODE" == "$1" ]] || die "Choose exactly one operation"
  MODE="$1"
}

need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }

while (($#)); do
  case "$1" in
    --download) set_mode download ;;
    --build) set_mode build ;;
    --list-disks) set_mode list-disks ;;
    --make-usb) set_mode make-usb ;;
    --verify) set_mode verify ;;
    --x64) EXPERIMENTAL_X64=1 ;;
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --retail) need_value "$@"; shift; RETAIL="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ -x "$MAIN" || -f "$MAIN" ]] || die "Main builder not found: $MAIN"

if (( EXPERIMENTAL_X64 == 1 )); then
  export ASPIRE4310_KERNEL_ARCH=x86_64
  OC_ARCH=x64
  KEXT_SET=smc
  EXPECTED_ARCH=x86_64
else
  export ASPIRE4310_KERNEL_ARCH=i386
  OC_ARCH=ia32
  KEXT_SET=minimal
  EXPECTED_ARCH=i386
fi

COMMON_ARGS=(
  --os snowleopard
  --oc-arch "$OC_ARCH"
  --kernel vanilla
  --runtime modern
  --kext-set "$KEXT_SET"
  --sata native
  --apic drop-duplicate
  --boot-preset diagnostic
)

build_and_validate() {
  local config="$ROOT_DIR/output/snowleopard/opencore-vanilla/ESP/EFI/OC/config.plist"
  local kext_root="$ROOT_DIR/output/snowleopard/opencore-vanilla/ESP/EFI/OC/Kexts"

  "$MAIN" --build "${COMMON_ARGS[@]}"
  [[ -f "$config" ]] || die "Build did not produce $config"

  python3 - "$config" "$EXPECTED_ARCH" <<'PY'
import plistlib, sys
path, expected = sys.argv[1], sys.argv[2]
with open(path, 'rb') as f:
    c = plistlib.load(f)
actual = c['Kernel']['Scheme']['KernelArch']
if actual != expected:
    raise SystemExit(f'KernelArch mismatch: expected {expected}, got {actual}')
args = c['NVRAM']['Add']['7C436110-AB2A-4BBB-A880-FE41995C9F82']['boot-args']
if expected == 'x86_64' and 'arch=x86_64' not in args.split():
    raise SystemExit('x86_64 profile is missing arch=x86_64 boot argument')
print(f'OpenCore config: KernelArch={actual}; boot-args={args!r}')
PY

  if [[ "$EXPECTED_ARCH" == x86_64 && -d "$kext_root" ]]; then
    python3 - "$kext_root" <<'PY'
import plistlib, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
for info in root.rglob('*.kext/Contents/Info.plist'):
    with info.open('rb') as f:
        p = plistlib.load(f)
    exe = p.get('CFBundleExecutable')
    if not exe:
        continue
    binary = info.parent / 'MacOS' / exe
    if not binary.exists():
        raise SystemExit(f'Missing kext executable: {binary}')
    proc = subprocess.run(['lipo', '-archs', str(binary)], text=True, capture_output=True)
    if proc.returncode:
        raise SystemExit(f'lipo failed for {binary}: {proc.stderr.strip()}')
    arches = proc.stdout.split()
    print(f'{binary}: {" ".join(arches)}')
    if 'x86_64' not in arches:
        raise SystemExit(f'x64 build rejected: {binary} has no x86_64 slice')
PY
  fi
}

case "$MODE" in
  download)
    "$MAIN" --download
    ;;
  build)
    build_and_validate
    ;;
  list-disks)
    "$MAIN" --list-disks
    ;;
  make-usb)
    [[ -n "$DISK" ]] || die "--make-usb requires --disk /dev/diskX"
    if [[ -z "$RETAIL" ]]; then
      if [[ -f "$ROOT_DIR/input/SnowLeopard-Retail.iso" ]]; then
        RETAIL="$ROOT_DIR/input/SnowLeopard-Retail.iso"
      elif [[ -f "$ROOT_DIR/input/SnowLeopard-Retail.dmg" ]]; then
        RETAIL="$ROOT_DIR/input/SnowLeopard-Retail.dmg"
      else
        die "Pass --retail or place input/SnowLeopard-Retail.iso/.dmg"
      fi
    fi
    build_and_validate
    "$MAIN" --make-usb "${COMMON_ARGS[@]}" --disk "$DISK" --retail "$RETAIL"
    ;;
  verify)
    [[ -n "$DISK" ]] || die "--verify requires --disk /dev/diskX"
    "$MAIN" --verify-usb --disk "$DISK"
    ;;
  "") usage; exit 1 ;;
  *) die "Unexpected mode: $MODE" ;;
esac
