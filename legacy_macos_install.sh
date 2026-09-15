#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILES_DIR="$ROOT_DIR/profiles"
TARGET=""
OS_PROFILE=""
USB_PROBE=0
FORWARD=()

usage() {
  cat <<'EOF'
Weird Legacy Laptops macOS Install Kit

Human-facing dispatcher. Existing build engines and their command semantics are
kept intact behind target/OS profiles.

Usage:
  ./legacy_macos_install.sh --target acer-aspire-4310 --os leopard --doctor
  ./legacy_macos_install.sh --target acer-aspire-4310 --os snowleopard --build
  ./legacy_macos_install.sh --target emachines-d640-n930 --os snowleopard --doctor
  ./legacy_macos_install.sh --target emachines-d640-n930 --os snowleopard --make-usb --disk /dev/sdX --retail /path/to.iso

Discovery:
  ./legacy_macos_install.sh --list-targets
  ./legacy_macos_install.sh --list-profiles

Legacy-BIOS USB probe (explicitly destructive and opt-in):
  ./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe --list
  sudo ./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe --disk /dev/sdX --case mbr-direct

Target selection:
  --target acer-aspire-4310 | emachines-d640-n930
  --os leopard | snowleopard | lion | mountainlion | mavericks

All other arguments are passed to the selected implementation. The original
Acer entry point ./prepare_aspire4310_macos.sh remains supported unchanged.

Lion and newer profiles use the OpenCore online-Recovery architecture
(com.apple.recovery.boot + recovery DMG/chunklist downloaded by macrecovery.py).
Profiles marked 'planned' are metadata/documentation only until their hardware
kernel/kext path has been validated; destructive/build operations are rejected.
EOF
}

log() { printf '[legacy-macos] %s\n' "$*"; }
die() { printf '[legacy-macos] ERROR: %s\n' "$*" >&2; exit 1; }
need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }

list_targets() {
  cat <<'EOF'
acer-aspire-4310       Acer Aspire 4310 / Celeron M 520 / GMA950
emachines-d640-n930    eMachines D640 / Phenom II N930 / Mobility Radeon HD 5470
EOF
}

list_profiles() {
  local target os file status method name
  for target in acer-aspire-4310 emachines-d640-n930; do
    for os in leopard snowleopard lion mountainlion mavericks; do
      file="$PROFILES_DIR/$target/$os/profile.conf"
      [[ -f "$file" ]] || continue
      PROFILE_STATUS="supported"
      INSTALL_METHOD="retail-media"
      OS_NAME="$os"
      # shellcheck disable=SC1090
      source "$file"
      status="${PROFILE_STATUS:-supported}"
      method="${INSTALL_METHOD:-retail-media}"
      name="${OS_NAME:-$os}"
      printf '%-24s %-14s %-12s %-15s %s\n' "$target" "$os" "$status" "$method" "$name"
    done
  done
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while (($#)); do
  case "$1" in
    --target)
      need_value "$@"; shift; TARGET="$1"
      ;;
    --os)
      need_value "$@"; shift; OS_PROFILE="$1"
      ;;
    --usb-probe)
      USB_PROBE=1
      ;;
    --list-targets)
      list_targets; exit 0
      ;;
    --list-profiles)
      printf '%-24s %-14s %-12s %-15s %s\n' TARGET OS STATUS METHOD NAME
      list_profiles
      exit 0
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      FORWARD+=("$1")
      ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || TARGET="acer-aspire-4310"

case "$TARGET" in
  acer-aspire-4310|emachines-d640-n930) ;;
  *) die "unknown target '$TARGET' (use --list-targets)" ;;
esac

if (( USB_PROBE == 1 )); then
  [[ "$TARGET" == "emachines-d640-n930" ]] || die "--usb-probe is currently defined only for emachines-d640-n930"
  exec bash "$ROOT_DIR/scripts/d640_usb_boot_probe.sh" "${FORWARD[@]}"
fi

if [[ -z "$OS_PROFILE" ]]; then
  if [[ "$TARGET" == "acer-aspire-4310" ]]; then
    OS_PROFILE="leopard"
  else
    OS_PROFILE="snowleopard"
  fi
fi

PROFILE="$PROFILES_DIR/$TARGET/$OS_PROFILE/profile.conf"
[[ -f "$PROFILE" ]] || die "profile not found: $TARGET/$OS_PROFILE (use --list-profiles)"

PROFILE_STATUS="supported"
INSTALL_METHOD="retail-media"
OS_NAME="$OS_PROFILE"
NOTES=""
# shellcheck disable=SC1090
source "$PROFILE"

if [[ "${PROFILE_STATUS:-supported}" == "planned" ]]; then
  for arg in "${FORWARD[@]}"; do
    if [[ "$arg" == "--doctor" ]]; then
      printf 'Target: %s\nOS: %s\nStatus: planned\nInstall method: %s\n' "$TARGET" "$OS_NAME" "${INSTALL_METHOD:-online-recovery}"
      [[ -n "${NOTES:-}" ]] && printf 'Notes: %s\n' "$NOTES"
      exit 0
    fi
  done
  die "$TARGET/$OS_PROFILE is a planned profile. Recovery architecture is documented, but build/USB operations are disabled until hardware-specific kernel/kext validation is complete."
fi

case "$TARGET:$OS_PROFILE" in
  acer-aspire-4310:leopard|acer-aspire-4310:snowleopard)
    log "target=$TARGET os=$OS_PROFILE engine=prepare_aspire4310_macos.sh"
    exec "$ROOT_DIR/prepare_aspire4310_macos.sh" --os "$OS_PROFILE" "${FORWARD[@]}"
    ;;
  emachines-d640-n930:snowleopard)
    D640_ARGS=()
    for arg in "${FORWARD[@]}"; do
      case "$arg" in
        --verify-usb) D640_ARGS+=(--verify) ;;
        *) D640_ARGS+=("$arg") ;;
      esac
    done
    log "target=$TARGET os=$OS_PROFILE engine=prepare_emachines_d640_snowleopard.sh"
    exec "$ROOT_DIR/scripts/prepare_emachines_d640_snowleopard.sh" "${D640_ARGS[@]}"
    ;;
  *)
    die "no implementation engine is enabled for $TARGET/$OS_PROFILE"
    ;;
esac
