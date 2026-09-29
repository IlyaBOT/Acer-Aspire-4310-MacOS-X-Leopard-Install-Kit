#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_REPO="Carnations-Botanica/AMD-Kernel-Patches"
SOURCE_COMMIT="f6860343d6a13ae954a0043cecb04a809faba0f8"
CACHE_ROOT="${AMD_KERNEL_CACHE:-$ROOT_DIR/cache/amd-kernels}"

OS=""
OUTPUT=""
PRINT_PATH=0

log() { printf '[amd-kernel] %s\n' "$*"; }
die() { printf '[amd-kernel] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }

usage() {
  cat <<'EOF'
Download the pinned Carnations Botanica legacy AMD mach_kernel matching an OS.

Usage:
  ./scripts/download_carnations_amd_kernel.sh --os snowleopard
  ./scripts/download_carnations_amd_kernel.sh --os lion
  ./scripts/download_carnations_amd_kernel.sh --os mountainlion
  ./scripts/download_carnations_amd_kernel.sh --os mavericks
  ./scripts/download_carnations_amd_kernel.sh --os mavericks --output /tmp/mach_kernel

Options:
  --os NAME       snowleopard | lion | mountainlion | mavericks
  --output PATH   copy/download the selected kernel to this exact path
  --print-path    print the final kernel path after validation

The source is pinned to a specific AMD-Kernel-Patches commit and every downloaded
kernel is verified against its Git blob SHA before use.
EOF
}

while (($#)); do
  case "$1" in
    --os) need_value "$@"; shift; OS="$1" ;;
    --output) need_value "$@"; shift; OUTPUT="$1" ;;
    --print-path) PRINT_PATH=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$OS" ]] || { usage; exit 2; }

case "$OS" in
  snowleopard)
    REL_PATH="extras/kernels/snowleopard/mach_kernel"
    BLOB_SHA="32e2a01c88a46a15f33b4cd69f88251cc0a6961a"
    DARWIN_MAJOR="10"
    ;;
  lion)
    REL_PATH="extras/kernels/lion/mach_kernel"
    BLOB_SHA="b9278deff8281dbd45f848d881c0f33071198d14"
    DARWIN_MAJOR="11"
    ;;
  mountainlion)
    REL_PATH="extras/kernels/mountainlion/mach_kernel"
    BLOB_SHA="68cc1f3cae39ae0e85abb00b9ab6c0c81d5b4d28"
    DARWIN_MAJOR="12"
    ;;
  mavericks)
    REL_PATH="extras/kernels/mavericks/mach_kernel"
    BLOB_SHA="cfdf0513edd8c57ed7f9b7c2d1f90090425b00fd"
    DARWIN_MAJOR="13"
    ;;
  *)
    die "Unsupported --os '$OS'; expected snowleopard, lion, mountainlion or mavericks"
    ;;
esac

for cmd in curl python3; do
  have "$cmd" || die "Missing required command: $cmd"
done

CACHE_FILE="$CACHE_ROOT/$OS/mach_kernel"
FINAL_PATH="${OUTPUT:-$CACHE_FILE}"
URL="https://raw.githubusercontent.com/$SOURCE_REPO/$SOURCE_COMMIT/$REL_PATH"

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
    raise SystemExit(
        f"Git blob SHA mismatch for {p}: expected {expected}, got {actual}"
    )
PY
}

validate_kernel() {
  local path="$1" darwin="$2"
  python3 - "$path" "$darwin" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
major=sys.argv[2]
data=p.read_bytes()

if not data.startswith((
    b"\xcf\xfa\xed\xfe",
    b"\xce\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
)):
    raise SystemExit(f"{p}: not a recognised Mach-O/FAT kernel")

needles=(
    f"Darwin Kernel Version {major}.".encode(),
    {
        "10": b"xnu-1504",
        "11": b"xnu-1699",
        "12": b"xnu-2050",
        "13": b"xnu-2422",
    }[major],
)
if not any(n in data for n in needles):
    raise SystemExit(
        f"{p}: kernel does not identify as expected Darwin {major}.x"
    )
PY
}

download_to() {
  local output="$1"
  mkdir -p "$(dirname "$output")"
  if [[ -s "$output" ]]       && verify_git_blob "$output" "$BLOB_SHA" >/dev/null 2>&1       && validate_kernel "$output" "$DARWIN_MAJOR" >/dev/null 2>&1; then
    log "Using validated cached kernel: $output"
    return 0
  fi

  rm -f -- "$output" "$output.part"
  log "Downloading $REL_PATH"
  curl -fL --retry 3 --connect-timeout 20 --max-time 300     -o "$output.part" "$URL"
  [[ -s "$output.part" ]] || die "Downloaded kernel is empty"
  verify_git_blob "$output.part" "$BLOB_SHA"
  validate_kernel "$output.part" "$DARWIN_MAJOR"
  mv -- "$output.part" "$output"
  chmod 0644 "$output"
}

if [[ "$FINAL_PATH" == "$CACHE_FILE" ]]; then
  download_to "$CACHE_FILE"
else
  download_to "$CACHE_FILE"
  mkdir -p "$(dirname "$FINAL_PATH")"
  cp -f -- "$CACHE_FILE" "$FINAL_PATH"
  verify_git_blob "$FINAL_PATH" "$BLOB_SHA"
  validate_kernel "$FINAL_PATH" "$DARWIN_MAJOR"
  chmod 0644 "$FINAL_PATH"
fi

cat > "$(dirname "$CACHE_FILE")/SOURCE.txt" <<EOF
source_repo=$SOURCE_REPO
source_commit=$SOURCE_COMMIT
os=$OS
kernel_path=$REL_PATH
kernel_git_blob=$BLOB_SHA
darwin_major=$DARWIN_MAJOR
EOF

log "Selected OS: $OS"
log "Darwin major: $DARWIN_MAJOR"
log "Kernel blob: $BLOB_SHA"
log "Kernel ready: $FINAL_PATH"

if (( PRINT_PATH == 1 )); then
  printf '%s\n' "$FINAL_PATH"
fi
