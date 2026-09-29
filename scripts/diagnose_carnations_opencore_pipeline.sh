#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_COMMIT="4d0803b5c1dbb12378e35712b213e531adde1d88"
PATCH_REV="2"

HELPER="$ROOT_DIR/scripts/build_carnations_opencore.sh"
VENDOR_ZIP="$ROOT_DIR/vendor/carnations-opencore/OpenCore-1.0.5-DEBUG.zip"
CACHE_BIN="$ROOT_DIR/cache/carnations-opencore/${SOURCE_COMMIT}-r${PATCH_REV}/X64/EFI/OC/OpenCore.efi"
OUTPUT_BIN="$ROOT_DIR/output/targets/asrock-fm2a58m-vg3-a8-7600/mavericks/opencore-custom/ESP/EFI/OC/OpenCore.efi"
USB_BIN="/mnt/EFI/OC/OpenCore.efi"

MARKERS=(
  "Original mach_kernel is absent"
  "ESP mach_kernel fallback"
  "trying ESP Kernels fallback"
)

have() { command -v "$1" >/dev/null 2>&1; }

sha256_file() {
  local path="$1"
  if have sha256sum; then
    sha256sum "$path" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    printf 'UNAVAILABLE'
  fi
}

check_markers() {
  local path="$1"
  python3 - "$path" "${MARKERS[@]}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
for marker in sys.argv[2:]:
    state = "FOUND" if marker.encode("ascii") in data else "NOT FOUND"
    print(f"    {state:9} {marker}")
PY
}

show_binary() {
  local label="$1"
  local path="$2"
  printf '\n[%s]\n%s\n' "$label" "$path"
  if [[ ! -f "$path" ]]; then
    printf '  MISSING\n'
    return 0
  fi
  printf '  size:   %s bytes\n' "$(wc -c < "$path" | tr -d ' ')"
  printf '  sha256: %s\n' "$(sha256_file "$path")"
  printf '  markers:\n'
  check_markers "$path"
}

have python3 || { printf 'ERROR: python3 is required\n' >&2; exit 1; }

printf '=== Git ===\n'
printf 'HEAD: '
git -C "$ROOT_DIR" rev-parse HEAD
printf 'branch: '
git -C "$ROOT_DIR" branch --show-current 2>/dev/null || true
printf 'status:\n'
git -C "$ROOT_DIR" status --short

printf '\n=== Source patch marker in helper ===\n'
grep -nE 'LOCAL_PATCH_REV=|Original mach_kernel is absent|ESP mach_kernel fallback|trying ESP Kernels fallback' "$HELPER" || true

printf '\n=== Vendored ZIP ===\n'
printf '%s\n' "$VENDOR_ZIP"
if [[ -f "$VENDOR_ZIP" ]]; then
  printf '  size:   %s bytes\n' "$(wc -c < "$VENDOR_ZIP" | tr -d ' ')"
  printf '  sha256: %s\n' "$(sha256_file "$VENDOR_ZIP")"
  if [[ -f "$VENDOR_ZIP.sha256" ]]; then
    printf '  recorded checksum: '
    cat "$VENDOR_ZIP.sha256"
  fi
else
  printf '  MISSING\n'
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/carnations-oc-diagnose.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

if [[ -f "$VENDOR_ZIP" ]]; then
  python3 - "$VENDOR_ZIP" "$TMP_DIR/OpenCore.efi" <<'PY'
from pathlib import Path
import shutil
import sys
import zipfile

archive = Path(sys.argv[1])
dest = Path(sys.argv[2])
member = "X64/EFI/OC/OpenCore.efi"

with zipfile.ZipFile(archive) as zf:
    with zf.open(member) as src, dest.open("wb") as out:
        shutil.copyfileobj(src, out)
PY
  show_binary "vendor ZIP / X64/EFI/OC/OpenCore.efi" "$TMP_DIR/OpenCore.efi"
fi

show_binary "expected r2 cache" "$CACHE_BIN"

printf '\n=== Other cached OpenCore.efi files ===\n'
found_cache=0
while IFS= read -r path; do
  found_cache=1
  show_binary "cache candidate" "$path"
done < <(find "$ROOT_DIR/cache/carnations-opencore" -type f -path '*/X64/EFI/OC/OpenCore.efi' -print 2>/dev/null | sort)
if [[ "$found_cache" -eq 0 ]]; then
  printf 'none\n'
fi

show_binary "A8 Mavericks output" "$OUTPUT_BIN"
show_binary "USB /mnt" "$USB_BIN"

printf '\n=== Pipeline verdict hints ===\n'
printf 'The first stage where the marker changes from FOUND to NOT FOUND is where the patched binary is lost.\n'
printf 'If vendor is NOT FOUND but helper source marker is present, the committed vendor ZIP is stale.\n'
printf 'If vendor is FOUND but cache/output/USB is NOT FOUND, compare the SHA256 values above to identify the stale copy.\n'
