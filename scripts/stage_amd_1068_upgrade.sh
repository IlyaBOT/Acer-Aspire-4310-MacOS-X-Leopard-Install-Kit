#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
KERNEL_ENV="$ROOT_DIR/cache/amd-kernels.env"
OUT_DIR="$ROOT_DIR/output/targets/emachines-d640-n930/snowleopard/upgrade-10.6.8"
KERNEL=""

usage() {
  cat <<'USAGE'
Stage a Snow Leopard 10.6.8 AMD upgrade kit.

Usage:
  ./scripts/stage_amd_1068_upgrade.sh [--kernel /path/to/legacy_kernel] [--output DIR]

The generated directory is copied to the Snow Leopard machine before running the
10.6.8 Combo Update. After the Combo Update finishes, DO NOT reboot. Run the
included install-legacy-kernel-10.8.0.sh as root, verify its checks, then reboot.
USAGE
}

log() { printf '[1068-kit] %s\n' "$*"; }
die() { printf '[1068-kit] ERROR: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --kernel) [[ $# -gt 1 ]] || die "--kernel requires a path"; shift; KERNEL="$1" ;;
    --output) [[ $# -gt 1 ]] || die "--output requires a path"; shift; OUT_DIR="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

if [[ -z "$KERNEL" && -f "$KERNEL_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$KERNEL_ENV"
  KERNEL="${AMD_KERNEL_1068:-}"
fi
[[ -n "$KERNEL" && -f "$KERNEL" ]] || die "10.6.8 AMD kernel is missing. Run the D640 --download flow first or pass --kernel."

mkdir -p "$OUT_DIR"
cp -f "$KERNEL" "$OUT_DIR/legacy_kernel-10.8.0"
chmod 0644 "$OUT_DIR/legacy_kernel-10.8.0"
sha256sum "$OUT_DIR/legacy_kernel-10.8.0" > "$OUT_DIR/SHA256SUMS.txt"

combo="$(find "$ROOT_DIR/downloads" -maxdepth 2 -type f -iname '*10.6.8*.dmg' -print -quit 2>/dev/null || true)"
if [[ -n "$combo" ]]; then
  cp -f "$combo" "$OUT_DIR/$(basename "$combo")"
  (cd "$OUT_DIR" && sha256sum "$(basename "$combo")" >> SHA256SUMS.txt)
fi

cat > "$OUT_DIR/install-legacy-kernel-10.8.0.sh" <<'EOS'
#!/bin/bash
set -e

KERNEL="$(cd "$(dirname "$0")" && pwd)/legacy_kernel-10.8.0"
TARGET="/mach_kernel"
BACKUP="/mach_kernel.apple-10.8.0"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0"
  exit 1
fi

if [ ! -f "$KERNEL" ]; then
  echo "Missing $KERNEL"
  exit 1
fi

if command -v sw_vers >/dev/null 2>&1; then
  version="$(sw_vers -productVersion 2>/dev/null || true)"
  echo "Detected Mac OS X: ${version:-unknown}"
  case "$version" in
    10.6.8*) ;;
    *)
      echo "Refusing: this helper is for the post-Combo-Update 10.6.8 stage."
      echo "Finish the 10.6.8 Combo Update first, but DO NOT reboot."
      exit 1
      ;;
  esac
fi

if ! strings "$KERNEL" | grep -q 'Darwin Kernel Version 10.8.0'; then
  if ! strings "$KERNEL" | grep -q 'xnu-1504.15.3'; then
    echo "Kernel does not identify as Darwin 10.8.0 / xnu-1504.15.3"
    exit 1
  fi
fi

if [ -f "$TARGET" ] && [ ! -e "$BACKUP" ]; then
  cp -p "$TARGET" "$BACKUP"
  echo "Backed up Apple's kernel to $BACKUP"
fi

cp -f "$KERNEL" "$TARGET"
chown root:wheel "$TARGET"
chmod 0644 "$TARGET"

# Keep a named recovery copy as well; OpenCore's first-boot path still loads /mach_kernel.
cp -f "$KERNEL" /legacy_kernel
chown root:wheel /legacy_kernel
chmod 0644 /legacy_kernel

sync
echo "Installed AMD legacy Darwin 10.8.0 kernel."
echo "Do not use Software Update for another OS update without preparing the matching kernel first."
EOS
chmod +x "$OUT_DIR/install-legacy-kernel-10.8.0.sh"

cat > "$OUT_DIR/README.txt" <<EOF_README
Snow Leopard 10.6.8 AMD upgrade kit for eMachines D640 / Phenom II N930

1. Boot the working 10.6.3 system.
2. Make a backup.
3. Run Apple's Mac OS X 10.6.8 Combo Update.
4. When the Combo Update asks to restart, DO NOT RESTART.
5. Open Terminal in this directory and run:
     sudo ./install-legacy-kernel-10.8.0.sh
6. Verify that it reports Darwin 10.8.0 / xnu-1504.15.3.
7. Reboot with OpenCore using the D640 profile.

The first boot remains i386-user32 + Cacheless + LegacyCommpage for the N930.
The script backs up the Apple kernel as /mach_kernel.apple-10.8.0.
EOF_README

log "Upgrade kit staged at $OUT_DIR"
