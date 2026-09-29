#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CACHE_ROOT="${A8_MAVERICKS_CACHE:-$ROOT_DIR/cache/a8-7600-mavericks}"
AMD_ROOT="$CACHE_ROOT/amd"
KEXT_ROOT="$CACHE_ROOT/kexts"
AMD_COMMIT="f6860343d6a13ae954a0043cecb04a809faba0f8"

PATCH_URL="https://raw.githubusercontent.com/Carnations-Botanica/AMD-Kernel-Patches/$AMD_COMMIT/10-9-Mavericks.plist"
PATCH_BLOB="b16798f398192f097d81243ea8eacda38305ef7d"
KERNEL_URL="https://raw.githubusercontent.com/Carnations-Botanica/AMD-Kernel-Patches/$AMD_COMMIT/extras/kernels/mavericks/mach_kernel"
KERNEL_BLOB="cfdf0513edd8c57ed7f9b7c2d1f90090425b00fd"

RTL_COMMIT="60d18d064988ed2a62206de55d682c8f1b77e92d"
RTL_BASE="https://raw.githubusercontent.com/sqlsec/clover/$RTL_COMMIT/HP_%E6%83%A0%E6%99%AE/%E6%83%A0%E6%99%AE%20Elitebook%208%E7%B3%BB%E5%88%97%E7%AC%94%E8%AE%B0%E6%9C%AC/CLOVER/kexts/10.9/RealtekRTL8111.kext/Contents"
RTL_INFO_BLOB="7c995a0238a29b4cbf077374a44f75e7674b9fea"
RTL_BIN_BLOB="ddd53a103f797f218c743fefca7e8a05e786f24b"

log() { printf '[a8-mavericks-assets] %s\n' "$*"; }
die() { printf '[a8-mavericks-assets] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

for cmd in curl python3; do have "$cmd" || die "Missing required command: $cmd"; done
mkdir -p "$AMD_ROOT" "$KEXT_ROOT"

verify_git_blob() {
  local path="$1" expected="$2"
  python3 - "$path" "$expected" <<'PY'
import hashlib
from pathlib import Path
import sys
p=Path(sys.argv[1])
expected=sys.argv[2].lower()
data=p.read_bytes()
actual=hashlib.sha1(b"blob "+str(len(data)).encode("ascii")+b"\0"+data).hexdigest()
if actual != expected:
    raise SystemExit(f"Git blob SHA mismatch for {p}: expected {expected}, got {actual}")
PY
}

download_blob() {
  local url="$1" expected="$2" output="$3"
  if [[ -s "$output" ]]; then
    if verify_git_blob "$output" "$expected" 2>/dev/null; then
      log "Using cached $(basename "$output")"
      return 0
    fi
    rm -f -- "$output"
  fi
  mkdir -p "$(dirname "$output")"
  log "Downloading $url"
  curl -fL --retry 3 --connect-timeout 20 --max-time 180 -o "$output.part" "$url"
  [[ -s "$output.part" ]] || die "Empty download: $url"
  verify_git_blob "$output.part" "$expected" || { rm -f "$output.part"; exit 1; }
  mv -- "$output.part" "$output"
}

download_blob "$PATCH_URL" "$PATCH_BLOB" "$AMD_ROOT/10-9-Mavericks.plist"
download_blob "$KERNEL_URL" "$KERNEL_BLOB" "$AMD_ROOT/mach_kernel"

python3 - "$AMD_ROOT/10-9-Mavericks.plist" "$AMD_ROOT/mach_kernel" <<'PY'
from pathlib import Path
import plistlib
import sys
patch=Path(sys.argv[1])
kernel=Path(sys.argv[2])
with patch.open("rb") as f:
    obj=plistlib.load(f)
patches=obj.get("Kernel",{}).get("Patch")
if not isinstance(patches,list) or len(patches) < 10:
    raise SystemExit("Mavericks AMD patch plist does not contain the expected Kernel/Patch set")
core=[x for x in patches if "cpuid_cores_per_package" in str(x.get("Comment",""))]
if len(core) != 1 or core[0].get("Replace") != b"\xBA\x00\x00\x00\x00":
    raise SystemExit("Unexpected Mavericks core-count patch template")
data=kernel.read_bytes()
if not data.startswith((b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")):
    raise SystemExit("Downloaded mach_kernel does not look like a Mach-O/FAT binary")
if b"Darwin Kernel Version 13." not in data and b"xnu-2422" not in data:
    raise SystemExit("Downloaded mach_kernel does not identify as a Mavericks/Darwin 13 kernel")
print(f"AMD patch set: {len(patches)} patches")
print(f"DEBUG mach_kernel: {len(data)} bytes")
PY
chmod 0644 "$AMD_ROOT/mach_kernel" "$AMD_ROOT/10-9-Mavericks.plist"

RTL="$KEXT_ROOT/RealtekRTL8111.kext"
mkdir -p "$RTL/Contents/MacOS"
download_blob "$RTL_BASE/Info.plist" "$RTL_INFO_BLOB" "$RTL/Contents/Info.plist"
download_blob "$RTL_BASE/MacOS/RealtekRTL8111" "$RTL_BIN_BLOB" "$RTL/Contents/MacOS/RealtekRTL8111"
chmod 0755 "$RTL/Contents/MacOS/RealtekRTL8111"
chmod 0644 "$RTL/Contents/Info.plist"

python3 - "$RTL/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],"rb") as f:
    p=plistlib.load(f)
if p.get("CFBundleIdentifier") != "com.insanelymac.RealtekRTL8111":
    raise SystemExit("Unexpected RealtekRTL8111 bundle identifier")
if p.get("CFBundleVersion") != "1.2.3":
    raise SystemExit("Expected legacy RealtekRTL8111 1.2.3")
match=p.get("IOKitPersonalities",{}).get("RTL8111 PCIe Adapter",{}).get("IOPCIMatch","")
if "0x816810ec" not in match.lower():
    raise SystemExit("RealtekRTL8111 profile does not include PCI ID 10EC:8168")
PY

cat > "$AMD_ROOT/SOURCE.txt" <<EOF
source_repo=Carnations-Botanica/AMD-Kernel-Patches
source_commit=$AMD_COMMIT
patch_path=10-9-Mavericks.plist
patch_git_blob=$PATCH_BLOB
kernel_path=extras/kernels/mavericks/mach_kernel
kernel_git_blob=$KERNEL_BLOB
note=Mavericks and below require the upstream stock DEBUG kernel in addition to OpenCore patches.
EOF

cat > "$RTL/SOURCE.txt" <<EOF
source=historical RealtekRTL8111 1.2.3 binary
redistribution_repo=sqlsec/clover
redistribution_commit=$RTL_COMMIT
info_git_blob=$RTL_INFO_BLOB
binary_git_blob=$RTL_BIN_BLOB
device=10EC:8168
note=Version 1.2.3 is selected for Mavericks-era compatibility; this binary is not from a current Mieze release.
EOF

log "AMD assets: $AMD_ROOT"
log "Realtek kext: $RTL"
