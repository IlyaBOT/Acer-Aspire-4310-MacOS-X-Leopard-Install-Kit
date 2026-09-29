#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILES_DIR="$ROOT_DIR/profiles"
OC_SELECTOR="$ROOT_DIR/scripts/select_opencore_release.sh"
GENERIC_PROFILE_HELPER="$ROOT_DIR/scripts/generic_pc_profile.py"
TARGET=""
OS_PROFILE=""
HARDWARE_PROFILE=""
USB_PROBE=0
OPENCORE_VERSION=""
OPENCORE_VARIANT=""
FORWARD=()

usage() {
  cat <<'EOF'
Weird Legacy Laptops macOS Install Kit

Human-facing dispatcher. Existing build engines and their command semantics are
kept intact behind target/OS profiles.

Usage:
  ./legacy_macos_install.sh --target acer-aspire-4310 --os leopard --doctor
  ./legacy_macos_install.sh --target acer-aspire-4310 --os snowleopard --build
  ./legacy_macos_install.sh --target acer-aspire-4310-c2d-t7400 --os snowleopard --build --kext-set sensors
  ./legacy_macos_install.sh --target emachines-d640-n930 --os snowleopard --doctor
  ./legacy_macos_install.sh --target emachines-d640-n930 --os snowleopard --make-usb --disk /dev/sdX --retail /path/to.iso
  ./legacy_macos_install.sh --target asus-eee-pc-1215p --os snowleopard --doctor
  ./legacy_macos_install.sh --target asus-eee-pc-1215p --os lion --doctor
  ./legacy_macos_install.sh --target asrock-fm2a58m-vg3-a8-7600 --os mavericks --doctor
  ./legacy_macos_install.sh --target asrock-fm2a58m-vg3-a8-7600 --os mavericks --build
  sudo ./legacy_macos_install.sh --target asrock-fm2a58m-vg3-a8-7600 --os mavericks --make-usb --disk /dev/sdX

Generic x86/x86_64 hardware analysis:
  ./legacy_macos_install.sh --profile universal --doctor
  ./legacy_macos_install.sh --profile new --os mavericks --doctor
  ./legacy_macos_install.sh --profile new --os mavericks --doctor --name "Friend AMD PC"
  ./legacy_macos_install.sh --profile <generated-slug> --doctor

  --profile universal|universal-x86  inspect the current x86 PC without saving
  --profile new                     inspect and save a local hardware profile
  --profile <generated-slug>        show a previously generated local profile

New profiles are analysis-only. Missing or malformed hardware facts are reported
as WARN and omitted or replaced by a conservative fallback. At the end of an
interactive --profile new run, the tool suggests a name based on
OS-hostname + CPU-model + i386/AMD64 + PC/Laptop and asks for confirmation.

OpenCore release selection for implemented IA32/OpenDuet profiles:
  ./legacy_macos_install.sh --target emachines-d640-n930 --download \
    --opencore-version 1.0.2 --opencore-variant debug
  ./legacy_macos_install.sh --target asus-eee-pc-1215p --build \
    --opencore-version 1.0.2 --opencore-variant release

  --opencore-version latest|X.Y.Z   select a specific OpenCore release
  --opencore-variant debug|release  select DEBUG or RELEASE archive; default DEBUG

A custom release requested together with --download/--download-only is cached
under cache/opencore/<version>/<variant> after the target's normal dependency
preparation, then becomes the selected OpenCore source. For other operations the
requested release must already be cached. Aliases: --oc-version, --oc-variant.

Discovery:
  ./legacy_macos_install.sh --list-targets
  ./legacy_macos_install.sh --list-profiles

Generated hardware profiles are stored under profiles/generated/ and are kept
local/private by default because hostnames and hardware inventories may identify
a machine.

Legacy-BIOS USB probe (explicitly destructive and opt-in):
  ./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe --list
  sudo ./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe --disk /dev/sdX --case mbr-direct

Target selection:
  --target acer-aspire-4310 | acer-aspire-4310-c2d-t7400 | emachines-d640-n930 | asus-eee-pc-1215p | asrock-fm2a58m-vg3-a8-7600
  --os leopard | snowleopard | lion | mountainlion | mavericks

All other arguments are passed to the selected implementation. The original
Acer entry point ./prepare_aspire4310_macos.sh remains supported unchanged.

Profiles marked 'experimental' have a build/media implementation but still need
physical bring-up. Profiles marked 'planned' are metadata/documentation only;
build and destructive operations are rejected for them. A target may also carry
a hardware-test blocker even when its tooling remains available for research.
EOF
}

log() { printf '[legacy-macos] %s\n' "$*"; }
die() { printf '[legacy-macos] ERROR: %s\n' "$*" >&2; exit 1; }
need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }

list_targets() {
  cat <<'EOF'
acer-aspire-4310       Acer Aspire 4310 / stock Celeron M 520 / GMA950
acer-aspire-4310-c2d-t7400  Acer Aspire 4310 / Core 2 Duo T7400 upgrade / GMA950
emachines-d640-n930    eMachines D640 / Phenom II N930 / Mobility Radeon HD 5470
asus-eee-pc-1215p      ASUS Eee PC 1215P / Atom N570 / GMA3150
asrock-fm2a58m-vg3-a8-7600  ASRock FM2A58M-VG3+ R2.0 / AMD A8-7600 / Radeon HD 6670
EOF
}

list_generated_profiles() {
  local file slug name requested_os
  [[ -d "$PROFILES_DIR/generated" ]] || return 0
  for file in "$PROFILES_DIR"/generated/*/profile.conf; do
    [[ -f "$file" ]] || continue
    PROFILE_NAME=""
    PROFILE_REQUESTED_OS="analysis"
    # shellcheck disable=SC1090
    source "$file"
    slug="$(basename "$(dirname "$file")")"
    name="${PROFILE_NAME:-$slug}"
    requested_os="${PROFILE_REQUESTED_OS:-analysis}"
    printf '%-24s %-14s %-12s %-15s %s\n' "generated/$slug" "$requested_os" analysis read-only "$name"
  done
}

list_profiles() {
  local target os file status method name
  for target in acer-aspire-4310 acer-aspire-4310-c2d-t7400 emachines-d640-n930 asus-eee-pc-1215p asrock-fm2a58m-vg3-a8-7600; do
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
  list_generated_profiles
}

has_forward_arg() {
  local wanted="$1" arg
  for arg in "${FORWARD[@]}"; do
    [[ "$arg" == "$wanted" ]] && return 0
  done
  return 1
}

forward_requests_download() {
  has_forward_arg --download || has_forward_arg --download-only
}

normalize_oc_variant() {
  local value
  value="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  case "$value" in
    DEBUG|RELEASE) printf '%s\n' "$value" ;;
    *) die "--opencore-variant must be debug or release" ;;
  esac
}

opencore_override_requested() {
  [[ -n "$OPENCORE_VERSION" || -n "$OPENCORE_VARIANT" ]]
}

prepare_cached_opencore_selection() {
  local version="${OPENCORE_VERSION:-latest}" variant
  variant="$(normalize_oc_variant "${OPENCORE_VARIANT:-DEBUG}")"
  [[ -f "$OC_SELECTOR" ]] || die "OpenCore selector is missing: $OC_SELECTOR"
  bash "$OC_SELECTOR" --select-only --version "$version" --variant "$variant"
}

download_and_select_opencore() {
  local version="${OPENCORE_VERSION:-latest}" variant
  variant="$(normalize_oc_variant "${OPENCORE_VARIANT:-DEBUG}")"
  [[ -f "$OC_SELECTOR" ]] || die "OpenCore selector is missing: $OC_SELECTOR"
  bash "$OC_SELECTOR" --download --version "$version" --variant "$variant"
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while (($#)); do
  case "$1" in
    --target) need_value "$@"; shift; TARGET="$1" ;;
    --os) need_value "$@"; shift; OS_PROFILE="$1" ;;
    --profile) need_value "$@"; shift; HARDWARE_PROFILE="$1" ;;
    --opencore-version|--oc-version) need_value "$@"; shift; OPENCORE_VERSION="$1" ;;
    --opencore-variant|--oc-variant) need_value "$@"; shift; OPENCORE_VARIANT="$1" ;;
    --usb-probe) USB_PROBE=1 ;;
    --list-targets) list_targets; exit 0 ;;
    --list-profiles)
      printf '%-24s %-14s %-12s %-15s %s\n' TARGET OS STATUS METHOD NAME
      list_profiles
      exit 0
      ;;
    -h|--help) usage; exit 0 ;;
    *) FORWARD+=("$1") ;;
  esac
  shift
done


if [[ -n "$HARDWARE_PROFILE" ]]; then
  [[ -z "$TARGET" ]] || die "--profile cannot be combined with --target"
  (( USB_PROBE == 0 )) || die "--profile cannot be combined with --usb-probe"
  opencore_override_requested && die "OpenCore release selection does not apply to hardware-analysis profiles"
  [[ -f "$GENERIC_PROFILE_HELPER" ]] || die "generic profile helper is missing: $GENERIC_PROFILE_HELPER"
  command -v python3 >/dev/null 2>&1 || die "--profile requires python3"

  GENERIC_ARGS=()
  [[ -n "$OS_PROFILE" ]] && GENERIC_ARGS+=(--target-os "$OS_PROFILE")

  case "$HARDWARE_PROFILE" in
    new)
      exec python3 "$GENERIC_PROFILE_HELPER" --mode new "${GENERIC_ARGS[@]}" "${FORWARD[@]}"
      ;;
    universal|universal-x86|generic-x86)
      exec python3 "$GENERIC_PROFILE_HELPER" --mode universal "${GENERIC_ARGS[@]}" "${FORWARD[@]}"
      ;;
    *)
      exec python3 "$GENERIC_PROFILE_HELPER" --show "$HARDWARE_PROFILE" "${FORWARD[@]}"
      ;;
  esac
fi

[[ -n "$TARGET" ]] || TARGET="acer-aspire-4310"
case "$TARGET" in
  acer-aspire-4310|acer-aspire-4310-c2d-t7400|emachines-d640-n930|asus-eee-pc-1215p|asrock-fm2a58m-vg3-a8-7600) ;;
  *) die "unknown target '$TARGET' (use --list-targets)" ;;
esac

if (( USB_PROBE == 1 )); then
  [[ "$TARGET" == "emachines-d640-n930" ]] || die "--usb-probe is currently defined only for emachines-d640-n930"
  opencore_override_requested && die "OpenCore version selection does not apply to --usb-probe"
  exec bash "$ROOT_DIR/scripts/d640_usb_boot_probe.sh" "${FORWARD[@]}"
fi

if [[ -z "$OS_PROFILE" ]]; then
  case "$TARGET" in
    acer-aspire-4310) OS_PROFILE="leopard" ;;
    acer-aspire-4310-c2d-t7400|emachines-d640-n930|asus-eee-pc-1215p) OS_PROFILE="snowleopard" ;;
    asrock-fm2a58m-vg3-a8-7600) OS_PROFILE="mavericks" ;;
  esac
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
  die "$TARGET/$OS_PROFILE is a planned profile. Recovery/installer architecture is documented, but build/USB operations are disabled until hardware-specific kernel/kext validation is complete."
fi

run_with_optional_opencore_selection() {
  if opencore_override_requested; then
    if forward_requests_download; then
      "$@"
      download_and_select_opencore
      return
    fi
    prepare_cached_opencore_selection
  fi
  exec "$@"
}

case "$TARGET:$OS_PROFILE" in
  acer-aspire-4310:leopard|acer-aspire-4310:snowleopard)
    log "target=$TARGET os=$OS_PROFILE engine=prepare_aspire4310_macos.sh"
    run_with_optional_opencore_selection "$ROOT_DIR/prepare_aspire4310_macos.sh" --os "$OS_PROFILE" "${FORWARD[@]}"
    ;;
  acer-aspire-4310-c2d-t7400:snowleopard)
    log "target=$TARGET os=$OS_PROFILE engine=prepare_aspire4310_macos.sh variant=Core2Duo-T7400"
    run_with_optional_opencore_selection env ASPIRE4310_PROFILE_TARGET="$TARGET" \
      "$ROOT_DIR/prepare_aspire4310_macos.sh" --os "$OS_PROFILE" "${FORWARD[@]}"
    ;;
  emachines-d640-n930:snowleopard)
    D640_ARGS=()
    for arg in "${FORWARD[@]}"; do
      case "$arg" in
        --verify-usb) D640_ARGS+=(--verify) ;;
        *) D640_ARGS+=("$arg") ;;
      esac
    done
    log "target=$TARGET os=$OS_PROFILE engine=prepare_emachines_d640_snowleopard.sh status=${PROFILE_STATUS:-experimental} hardware=${HARDWARE_TEST_STATUS:-unknown}"
    run_with_optional_opencore_selection "$ROOT_DIR/scripts/prepare_emachines_d640_snowleopard.sh" "${D640_ARGS[@]}"
    ;;
  asus-eee-pc-1215p:snowleopard)
    log "target=$TARGET os=$OS_PROFILE engine=prepare_asus_1215p_snowleopard.sh status=${PROFILE_STATUS:-experimental}"
    run_with_optional_opencore_selection bash "$ROOT_DIR/scripts/prepare_asus_1215p_snowleopard.sh" "${FORWARD[@]}"
    ;;
  asrock-fm2a58m-vg3-a8-7600:mavericks)
    opencore_override_requested && die "The A8 Mavericks target pins the Carnations Botanica OpenCore fork; --opencore-version/variant do not apply"
    log "target=$TARGET os=$OS_PROFILE engine=prepare_asrock_a8_mavericks.sh status=${PROFILE_STATUS:-experimental}"
    exec bash "$ROOT_DIR/scripts/prepare_asrock_a8_mavericks.sh" "${FORWARD[@]}"
    ;;
  *) die "no implementation engine is enabled for $TARGET/$OS_PROFILE" ;;
esac
