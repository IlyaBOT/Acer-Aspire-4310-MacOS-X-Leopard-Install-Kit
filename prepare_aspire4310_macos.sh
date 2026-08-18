#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$SCRIPT_DIR"
CONFIG_DIR="$ROOT_DIR/config"
PROFILES_DIR="$ROOT_DIR/profiles"
INPUT_DIR="$ROOT_DIR/input"
DOWNLOADS_DIR="$ROOT_DIR/downloads"
CACHE_DIR="$ROOT_DIR/cache"
OUTPUT_DIR="$ROOT_DIR/output"
MANIFEST="$DOWNLOADS_DIR/manifest.tsv"
CURRENT_SOURCES="$CACHE_DIR/current-sources.env"
INSPECTOR="$ROOT_DIR/scripts/inspect_artifact.py"
CONFIG_GENERATOR="$ROOT_DIR/scripts/generate_oc_config.py"
TREE_VALIDATOR="$ROOT_DIR/scripts/validate_oc_tree.py"

# Project-owned constant files.
# shellcheck disable=SC1091
source "$CONFIG_DIR/aspire4310.conf"
# shellcheck disable=SC1091
source "$CONFIG_DIR/sources.conf"

MODE=""
OS_PROFILE="leopard"
BOOTLOADER="auto"
OC_ARCH="auto"
HFS_DRIVER="auto"
KERNEL_MODE="auto"
BOOT_PRESET="diagnostic"
KEXT_SET="minimal"
SATA_MODE="native"
ACPI_MODE="native"
APIC_MODE="native"
RUNTIME_PROFILE="auto"
RUNTIME_PROFILE_RESOLVED=""
DISK=""
RETAIL=""
AUDIT_VOLUME=""
USB_LAYOUT="fresh"
BOOT_SLICE=""
INSTALLER_SLICE=""
PROTECTED_VOLUMES=()
DRY_RUN=0
ALLOW_INTERNAL=0
SKIP_COMBO_UPDATES=0
ATTACHED_IMAGE_DEVICE=""
ATTACHED_RETAIL_VOLUME=""
TEMP_DIR=""

HOST_OS="unknown"
HOST_PRODUCT_NAME="unknown"
HOST_VERSION="unknown"
HOST_BUILD="unknown"
HOST_MAJOR="0"
HOST_MINOR="0"
HOST_ARCH="unknown"
HOST_CPU_BRAND="unknown"
HOST_CPU_KIND="unknown"
HOST_CODE_NAME="unknown"
HOST_TRANSLATED="no"
HOST_STATUS="UNSUPPORTED BUILD HOST"
SHELL_SYNTAX_STATUS="NOT RUN"
SHELLCHECK_STATUS="NOT RUN"
SHFMT_STATUS="NOT RUN"
OC_VERSION=""
OC_VARIANT=""
OC_CACHE_REL=""
OCBINARYDATA_SHA=""
HFS_LEGACY_FILE=""
HFS_32_FILE=""
LEGACY_KEXTS_SHA=""
LEGACY_KEXTS_CACHE_REL=""

usage() {
  cat <<'EOF'
Aspire 4310 legacy macOS installer builder

Read-only:
  ./prepare_aspire4310_macos.sh --doctor
  ./prepare_aspire4310_macos.sh --audit [--volume "/Volumes/BOOT"]
  ./prepare_aspire4310_macos.sh --list-disks
  ./prepare_aspire4310_macos.sh --verify-usb --disk /dev/diskX
  ./prepare_aspire4310_macos.sh --verify-usb --volume "/Volumes/BOOT"

Non-destructive project operations:
  ./prepare_aspire4310_macos.sh --download [--skip-combo-updates]
  ./prepare_aspire4310_macos.sh --build --os leopard
  ./prepare_aspire4310_macos.sh --build --os snowleopard

Replace only EFI/OpenDuet on an existing USB (macOS only):
  ./prepare_aspire4310_macos.sh --update-efi --os leopard --disk /dev/diskX \
    --boot-slice /dev/diskXs1

Destructive USB operation (macOS only; never automatic):
  ./prepare_aspire4310_macos.sh --make-usb --os leopard --disk /dev/diskX \
    --retail input/Leopard-Retail.iso

Preserve an existing first FAT boot partition and replace only partition 2:
  ./prepare_aspire4310_macos.sh --make-usb --layout preserve --disk /dev/diskX \
    --boot-slice /dev/diskXs1 --installer-slice /dev/diskXs2 \
    --retail input/Leopard-Retail.iso

Build choices:
  --bootloader auto|opencore|chameleon    default: auto (OpenCore first)
  --oc-arch auto|ia32|x64                default: auto (IA32 for i386 profiles)
  --hfs-driver auto|legacy|32|openhfs     default: auto
  --kernel auto|vanilla|custom            default: auto
  --boot-preset normal|verbose|safe|diagnostic
  --kext-set smc|minimal|full             default: minimal
  --sata native|injected                  default: native
  --acpi native|patched                   default: native
  --apic native|drop-duplicate            default: native
  --runtime auto|off|legacy|modern        default: auto (off for Leopard)
  --layout fresh|preserve                 default: fresh (whole disk is repartitioned)
  --boot-slice /dev/diskXs1               required by preserve layout/update-efi
  --installer-slice /dev/diskXs2          required by preserve layout; contents are erased
  --protect-volume "/Volumes/KEEP"         repeatable mounted-volume safety guard
  --dry-run                               print destructive commands only
  --allow-internal                        extra override; exact confirmation still required

The script never downloads a retail Mac OS X installer. Volume names are never hardcoded;
use --protect-volume for any mounted volume that must make a target disk ineligible.
EOF
}

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(timestamp)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(timestamp)" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  if [[ -n "${ATTACHED_IMAGE_DEVICE:-}" && "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
    hdiutil detach "$ATTACHED_IMAGE_DEVICE" >/dev/null 2>&1 || true
  fi
  if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
    case "$TEMP_DIR" in
      /tmp/aspire4310.*|"${TMPDIR:-/tmp}"/aspire4310.*) rm -rf -- "$TEMP_DIR" ;;
      *) warn "Refusing to clean unexpected temporary directory: $TEMP_DIR" ;;
    esac
  fi
}
trap cleanup EXIT INT TERM

on_error() {
  local line="$1"
  local status="$2"
  warn "Command failed at line $line (status $status). No USB action is retried automatically."
}
trap 'on_error "$LINENO" "$?"' ERR

ensure_project_dirs() {
  mkdir -p "$DOWNLOADS_DIR" "$CACHE_DIR" "$OUTPUT_DIR"
}

safe_remove_generated() {
  local path="$1"
  [[ -n "$path" && "$path" != "$OUTPUT_DIR" && "$path" == "$OUTPUT_DIR"/* ]] \
    || die "Refusing to remove non-generated path: $path"
  rm -rf -- "$path"
}

copy_tree() {
  local source="$1"
  local destination="$2"
  mkdir -p "$(dirname "$destination")"
  if have_cmd ditto; then
    ditto "$source" "$destination"
  else
    mkdir -p "$destination"
    cp -R "$source"/. "$destination"/
  fi
}

macos_codename() {
  local major="$1"
  local minor="$2"
  case "$major" in
    10) [[ "$minor" == "15" ]] && printf 'Catalina' || printf 'macOS 10.%s' "$minor" ;;
    11) printf 'Big Sur' ;;
    12) printf 'Monterey' ;;
    13) printf 'Ventura' ;;
    14) printf 'Sonoma' ;;
    15) printf 'Sequoia' ;;
    26) printf 'Tahoe' ;;
    *) printf 'newer/unknown macOS' ;;
  esac
}

detect_host() {
  local translated="0"
  local x64_optional=""

  HOST_OS="$(uname -s 2>/dev/null || printf unknown)"
  HOST_ARCH="$(uname -m 2>/dev/null || printf unknown)"
  if [[ "$HOST_OS" == "Darwin" ]] && have_cmd sw_vers; then
    HOST_PRODUCT_NAME="$(sw_vers -productName 2>/dev/null || printf macOS)"
    HOST_VERSION="$(sw_vers -productVersion 2>/dev/null || printf unknown)"
    HOST_BUILD="$(sw_vers -buildVersion 2>/dev/null || printf unknown)"
    HOST_MAJOR="${HOST_VERSION%%.*}"
    if [[ "$HOST_VERSION" == *.* ]]; then
      HOST_MINOR="${HOST_VERSION#*.}"
      HOST_MINOR="${HOST_MINOR%%.*}"
    else
      HOST_MINOR="0"
    fi
    [[ "$HOST_MAJOR" =~ ^[0-9]+$ ]] || HOST_MAJOR="0"
    [[ "$HOST_MINOR" =~ ^[0-9]+$ ]] || HOST_MINOR="0"
    HOST_CPU_BRAND="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || printf unknown)"
    x64_optional="$(sysctl -n hw.optional.x86_64 2>/dev/null || true)"
    translated="$(sysctl -in sysctl.proc_translated 2>/dev/null || printf 0)"
    HOST_CODE_NAME="$(macos_codename "$HOST_MAJOR" "$HOST_MINOR")"
    if [[ "$HOST_CPU_BRAND" == *Intel* || "$HOST_ARCH" == "x86_64" || "$x64_optional" == "1" ]]; then
      HOST_CPU_KIND="Intel"
    elif [[ "$HOST_ARCH" == "arm64" ]]; then
      HOST_CPU_KIND="Apple Silicon"
    else
      HOST_CPU_KIND="unknown"
    fi
    [[ "$translated" == "1" ]] && HOST_TRANSLATED="yes" || HOST_TRANSLATED="no"

    if [[ "$HOST_CPU_KIND" == "Intel" && "$HOST_ARCH" == "x86_64" ]]; then
      if (( HOST_MAJOR > 10 )) || (( HOST_MAJOR == 10 && HOST_MINOR >= 15 )); then
        HOST_STATUS="SUPPORTED BUILD HOST"
      fi
    fi
  else
    HOST_PRODUCT_NAME="$HOST_OS"
    HOST_CPU_BRAND="$(awk -F': *' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || printf unknown)"
    HOST_CPU_KIND="$HOST_ARCH"
    HOST_CODE_NAME="not macOS"
  fi
}

print_host_report() {
  printf 'Host OS: %s\n' "$HOST_PRODUCT_NAME"
  printf 'Host version: %s\n' "$HOST_VERSION"
  printf 'Host build: %s\n' "$HOST_BUILD"
  printf 'Host codename: %s\n' "$HOST_CODE_NAME"
  printf 'Host architecture: %s\n' "$HOST_ARCH"
  printf 'Host CPU: %s\n' "$HOST_CPU_KIND"
  printf 'Host CPU brand: %s\n' "$HOST_CPU_BRAND"
  printf 'Rosetta translation: %s\n' "$HOST_TRANSLATED"
  printf 'Status: %s\n' "$HOST_STATUS"
}

doctor_host() {
  local required='diskutil hdiutil asr plutil curl ditto file lipo shasum openssl awk sed grep find stat dd fdisk mount umount xattr python3'
  local optional='shellcheck shfmt jq'
  local command_name
  local failures=0

  detect_host
  print_host_report
  printf '\nRequired host tools:\n'
  for command_name in $required; do
    if have_cmd "$command_name"; then
      printf '  OK      %-12s %s\n' "$command_name" "$(command -v "$command_name")"
    else
      printf '  MISSING %s\n' "$command_name"
      failures=$((failures + 1))
    fi
  done
  printf '\nOptional quality tools:\n'
  for command_name in $optional; do
    if have_cmd "$command_name"; then
      printf '  OK      %-12s %s\n' "$command_name" "$(command -v "$command_name")"
    else
      printf '  WARN    %s (optional)\n' "$command_name"
    fi
  done
  printf '\nTarget is fixed independently of host: %s / %s / OpenDuet %s / kernel %s\n' \
    "$TARGET_MODEL" "$TARGET_CPU" "$TARGET_OPENCORE_ARCH" "$TARGET_KERNEL_ARCH"

  if [[ "$HOST_STATUS" != "SUPPORTED BUILD HOST" ]]; then
    warn "This environment can audit/download/build staging files, but destructive USB creation requires Intel macOS 10.15+."
    failures=$((failures + 1))
  fi
  (( failures == 0 ))
}

require_macos_build_host() {
  detect_host
  [[ "$HOST_STATUS" == "SUPPORTED BUILD HOST" ]] \
    || die "USB creation requires a supported Intel macOS build host; detected $HOST_PRODUCT_NAME $HOST_VERSION $HOST_ARCH."
}

is_protected_volume() {
  local candidate="${1%/}" protected
  for protected in "${PROTECTED_VOLUMES[@]}"; do
    [[ "$candidate" == "${protected%/}" ]] && return 0
  done
  return 1
}

audit_volume() {
  local volume="$1"
  is_protected_volume "$volume" && die "Protected volume is explicitly out of scope: $volume"
  printf '\nUSB volume audit (read-only): %s\n' "$volume"
  if [[ ! -d "$volume" ]]; then
    printf '  NOT AVAILABLE in this execution environment.\n'
    return 0
  fi
  printf '  Bootability markers:\n'
  for marker in boot EFI/BOOT/BOOTx64.efi EFI/BOOT/BOOTIA32.efi EFI/OC/OpenCore.efi EFI/OC/config.plist; do
    if [[ -e "$volume/$marker" ]]; then printf '    FOUND   %s\n' "$marker"; else printf '    MISSING %s\n' "$marker"; fi
  done
  printf '  Installer/image candidates:\n'
  find "$volume" -xdev -maxdepth 5 -type f \( \
    -iname '*.dmg' -o -iname '*.iso' -o -iname '*leopard*' -o -iname '*high*sierra*' \
  \) -print 2>/dev/null | sed 's/^/    /' || true
  printf '  EFI files:\n'
  find "$volume/EFI" -xdev -maxdepth 8 -type f ! -path '*/EFI/OC/Resources/*' -print 2>/dev/null \
    | sort | sed 's/^/    /' || true
  if [[ -f "$volume/EFI/OC/OpenCore.efi" ]]; then
    printf '  OpenCore binary metadata:\n'
    file "$volume/EFI/OC/OpenCore.efi" 2>/dev/null | sed 's/^/    /' || true
    strings "$volume/EFI/OC/OpenCore.efi" 2>/dev/null \
      | grep -E -m 3 'REL-[0-9]|DBG-[0-9]|OpenCore' | sed 's/^/    /' || true
  fi
  if [[ -f "$volume/EFI/OC/config.plist" ]]; then
    if have_cmd plutil; then plutil -lint "$volume/EFI/OC/config.plist" || true; fi
  fi
}

run_audit() {
  printf 'Project audit (read-only)\n'
  printf '  Root: %s\n' "$ROOT_DIR"
  printf '  Shell scripts:\n'
  find "$ROOT_DIR" -type f \( -name '*.sh' -o -name '*.command' -o -name '*.tool' \) -print | sort | sed 's/^/    /'
  printf '  Plists, archives, EFI binaries, kexts and logs:\n'
  find "$ROOT_DIR" -maxdepth 6 \( -type f -o -type d \) \( \
    -name '*.plist' -o -name '*.zip' -o -name '*.tar.gz' -o -name '*.dmg' -o -name '*.iso' \
    -o -name '*.efi' -o -name '*.kext' -o -name '*.log' -o -name EFI -o -name Extra \
  \) -print | sort | sed 's/^/    /' || true
  printf '  Git state:\n'
  git -C "$ROOT_DIR" status --short --branch 2>/dev/null | sed 's/^/    /' || printf '    not a Git worktree\n'
  cat <<'EOF'

Legacy implementation findings:
  KEEP: strict shell mode, quoted paths, exact ERASE confirmation, read-only retail attach,
        legal-retail policy, asr fallback, and target-era Chameleon knowledge.
  BROKEN/STALE: Chameleon-only MBR design, dead HTTP binary URL, unpinned master archive,
        no OpenCore/OpenDuet, no host doctor, no Snow Leopard profile, and no hashes/manifest.
  UNSAFE: the old external-disk test accepted any one weak USB/external/removable clue and did
        not explicitly reject Internal: Yes or support user-declared protected volumes.
  WRONG LAYERING: audio and battery kexts were placed in the first boot set; every legacy kext
        was copied without checking Mach-O slices, bundle metadata, dependencies, or OS floor.
  ARCHITECTURE: host uname was never used for target selection, but no independent target CPU
        research existed. The target is Intel-64/SSSE3; Leopard still requires i386 XNU/kexts.
  LOST MEDIA: the historical Chameleon URL is not trusted or downloaded automatically. A user-
        supplied archive remains supported as an explicit fallback.
EOF
  if [[ -n "$AUDIT_VOLUME" ]]; then
    audit_volume "$AUDIT_VOLUME"
  else
    printf '\nNo volume path supplied; project-only audit complete.\n'
  fi
}

sha256_file() {
  if shasum -a 256 "$1" >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

ensure_manifest() {
  if [[ ! -f "$MANIFEST" ]]; then
    printf 'timestamp\tsource\tversion\turl\tfilename\tsha256\tstatus\n' >"$MANIFEST"
  fi
}

manifest_confirms() {
  local url="$1" filename="$2" digest="$3"
  awk -F '\t' -v u="$url" -v f="$filename" -v h="$digest" \
    'NR > 1 && $4 == u && $5 == f && $6 == h && $7 == "VERIFIED" {found=1} END {exit !found}' "$MANIFEST"
}

record_manifest() {
  local source="$1" version="$2" url="$3" filename="$4" digest="$5"
  if ! manifest_confirms "$url" "$filename" "$digest"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\tVERIFIED\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$source" "$version" "$url" "$filename" "$digest" >>"$MANIFEST"
  fi
}

download_cached() {
  local url="$1" destination="$2" source="$3" version="$4"
  local filename digest temp_digest
  filename="$(basename "$destination")"
  ensure_manifest
  if [[ -s "$destination" ]]; then
    digest="$(sha256_file "$destination")"
    if manifest_confirms "$url" "$filename" "$digest"; then
      log "Verified cache hit: $filename"
      return 0
    fi
    warn "Existing $filename has no matching manifest entry; downloading once to compare."
    curl -fL --retry 3 --connect-timeout 20 -o "${destination}.verify.part" "$url"
    temp_digest="$(sha256_file "${destination}.verify.part")"
    if [[ "$digest" != "$temp_digest" ]]; then
      die "Existing $filename differs from current upstream. Both files were preserved (${destination}.verify.part)."
    fi
    rm -f -- "${destination}.verify.part"
    record_manifest "$source" "$version" "$url" "$filename" "$digest"
    return 0
  fi
  log "Downloading $source $version: $filename"
  curl -fL --retry 3 --connect-timeout 20 -o "${destination}.part" "$url"
  [[ -s "${destination}.part" ]] || die "Empty download: $url"
  mv -- "${destination}.part" "$destination"
  digest="$(sha256_file "$destination")"
  record_manifest "$source" "$version" "$url" "$filename" "$digest"
}

extract_zip_once() {
  local archive="$1" destination="$2" required_marker="$3"
  local staging
  if [[ -e "$destination/$required_marker" ]]; then return 0; fi
  [[ ! -e "$destination" ]] || die "Incomplete cache exists; preserve and inspect manually: $destination"
  staging="${destination}.extracting"
  [[ ! -e "$staging" ]] || die "Stale extraction directory exists: $staging"
  mkdir -p "$staging"
  if have_cmd ditto; then
    ditto -x -k "$archive" "$staging"
  elif have_cmd unzip; then
    unzip -q "$archive" -d "$staging"
  else
    python3 -m zipfile -e "$archive" "$staging"
  fi
  [[ -e "$staging/$required_marker" ]] || die "Archive did not contain $required_marker: $archive"
  mv -- "$staging" "$destination"
}

json_value() {
  local json_file="$1" expression="$2"
  python3 - "$json_file" "$expression" <<'PY'
import json,sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
expr=sys.argv[2]
if expr == 'tag': print(data['tag_name'])
elif expr.startswith('asset:'):
    suffix=expr.split(':',1)[1]
    for asset in data['assets']:
        if asset['name'].endswith(suffix):
            print(asset['browser_download_url']); break
elif expr == 'sha': print(data['sha'])
PY
}

extract_apple_dmg_url() {
  local page_file="$1"
  grep -Eo 'https://updates\.cdn-apple\.com[^"<>[:space:]]+\.dmg' "$page_file" \
    | sed 's/&amp;/\&/g' | head -n 1
}

run_download() {
  local oc_version oc_url oc_zip oc_cache
  local ocbinary_sha legacy_sha legacy_short legacy_zip legacy_cache legacy_top
  local hfs_name hfs_url apple_url apple_page_file

  have_cmd curl || die "curl is required for --download"
  have_cmd python3 || die "python3 is required for --download"
  ensure_project_dirs
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aspire4310.download.XXXXXX")"
  curl -fsSL --retry 3 "$OPENCORE_API" -o "$TEMP_DIR/opencore.json"
  oc_version="$(json_value "$TEMP_DIR/opencore.json" tag)"
  oc_url="$(json_value "$TEMP_DIR/opencore.json" 'asset:-DEBUG.zip')"
  [[ -n "$oc_version" && -n "$oc_url" ]] || die "Could not discover latest stable OpenCore DEBUG asset."
  oc_zip="$DOWNLOADS_DIR/OpenCore-${oc_version}-DEBUG.zip"
  download_cached "$oc_url" "$oc_zip" "OpenCorePkg" "$oc_version"
  oc_cache="$CACHE_DIR/opencore/$oc_version/DEBUG"
  extract_zip_once "$oc_zip" "$oc_cache" "Docs/Sample.plist"
  [[ -d "$oc_cache/Utilities/LegacyBoot" && -f "$oc_cache/Utilities/ocvalidate/ocvalidate" ]] \
    || die "OpenCore $oc_version lacks required LegacyBoot/ocvalidate components."

  curl -fsSL --retry 3 "$OCBINARYDATA_API" -o "$TEMP_DIR/ocbinary.json"
  ocbinary_sha="$(json_value "$TEMP_DIR/ocbinary.json" sha)"
  [[ "$ocbinary_sha" =~ ^[0-9a-f]{40}$ ]] || die "Could not resolve OcBinaryData master commit."
  for hfs_name in HfsPlusLegacy.efi HfsPlus32.efi; do
    hfs_url="https://raw.githubusercontent.com/acidanthera/OcBinaryData/$ocbinary_sha/Drivers/$hfs_name"
    download_cached "$hfs_url" "$DOWNLOADS_DIR/OcBinaryData-${ocbinary_sha:0:12}-$hfs_name" \
      "OcBinaryData/$hfs_name" "${ocbinary_sha:0:12}"
  done

  curl -fsSL --retry 3 "$LEGACY_KEXTS_API" -o "$TEMP_DIR/legacy-kexts.json"
  legacy_sha="$(json_value "$TEMP_DIR/legacy-kexts.json" sha)"
  [[ "$legacy_sha" =~ ^[0-9a-f]{40}$ ]] || die "Could not resolve Legacy-Kexts master commit."
  legacy_short="${legacy_sha:0:12}"
  legacy_url="https://api.github.com/repos/khronokernel/Legacy-Kexts/zipball/$legacy_sha"
  legacy_zip="$DOWNLOADS_DIR/Legacy-Kexts-$legacy_short.zip"
  download_cached "$legacy_url" "$legacy_zip" "khronokernel/Legacy-Kexts" "$legacy_short"
  legacy_cache="$CACHE_DIR/legacy-kexts/$legacy_short"
  if [[ ! -d "$legacy_cache/FAT" ]]; then
    [[ ! -e "$legacy_cache" ]] || die "Incomplete legacy kext cache exists: $legacy_cache"
    mkdir -p "$TEMP_DIR/legacy-extract"
    if have_cmd ditto; then ditto -x -k "$legacy_zip" "$TEMP_DIR/legacy-extract"; else unzip -q "$legacy_zip" -d "$TEMP_DIR/legacy-extract"; fi
    legacy_top="$(find "$TEMP_DIR/legacy-extract" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "$legacy_top" && -d "$legacy_top/FAT" ]] || die "Legacy-Kexts archive structure is unexpected."
    mkdir -p "$(dirname "$legacy_cache")"
    mv -- "$legacy_top" "$legacy_cache"
  fi

  if (( SKIP_COMBO_UPDATES == 0 )); then
    apple_page_file="$TEMP_DIR/apple-1058.html"
    apple_url=""
    if curl -fsSL --retry 3 "$APPLE_1058_PAGE" -o "$apple_page_file"; then apple_url="$(extract_apple_dmg_url "$apple_page_file" || true)"; fi
    [[ -n "$apple_url" ]] || apple_url="$APPLE_1058_FALLBACK_URL"
    download_cached "$apple_url" "$DOWNLOADS_DIR/$(basename "$apple_url")" "Apple 10.5.8 Combo Update" "10.5.8"

    apple_page_file="$TEMP_DIR/apple-1068.html"
    apple_url=""
    if curl -fsSL --retry 3 "$APPLE_1068_PAGE" -o "$apple_page_file"; then apple_url="$(extract_apple_dmg_url "$apple_page_file" || true)"; fi
    [[ -n "$apple_url" ]] || apple_url="$APPLE_1068_FALLBACK_URL"
    download_cached "$apple_url" "$DOWNLOADS_DIR/$(basename "$apple_url")" "Apple 10.6.8 Combo Update" "10.6.8-v1.1"
  else
    warn "Combo updates skipped by explicit --skip-combo-updates."
  fi

  cat >"$CURRENT_SOURCES" <<EOF
OC_VERSION=$oc_version
OC_VARIANT=DEBUG
OC_CACHE_REL=opencore/$oc_version/DEBUG
OCBINARYDATA_SHA=$ocbinary_sha
HFS_LEGACY_FILE=OcBinaryData-${ocbinary_sha:0:12}-HfsPlusLegacy.efi
HFS_32_FILE=OcBinaryData-${ocbinary_sha:0:12}-HfsPlus32.efi
LEGACY_KEXTS_SHA=$legacy_sha
LEGACY_KEXTS_CACHE_REL=legacy-kexts/$legacy_short
EOF
  log "Download/cache preparation complete: OpenCore $oc_version DEBUG, both OpenDuet architectures, pinned HFS drivers, pinned legacy kext candidates."
}

load_current_sources() {
  [[ -f "$CURRENT_SOURCES" ]] || die "Assets are not prepared. Run: ./prepare_aspire4310_macos.sh --download"
  # Project-generated, scalar-only cache metadata.
  # shellcheck disable=SC1090
  source "$CURRENT_SOURCES"
  OC_CACHE_ROOT="$CACHE_DIR/$OC_CACHE_REL"
  LEGACY_KEXTS_ROOT="$CACHE_DIR/$LEGACY_KEXTS_CACHE_REL"
  [[ -f "$OC_CACHE_ROOT/Docs/Sample.plist" && -d "$LEGACY_KEXTS_ROOT/FAT" ]] \
    || die "Asset cache is incomplete; inspect $CURRENT_SOURCES and rerun --download."
}

load_os_profile() {
  local profile="$PROFILES_DIR/$OS_PROFILE/profile.conf"
  [[ -f "$profile" ]] || die "OS profile is missing: $profile"
  # Project-owned scalar profile metadata.
  # shellcheck disable=SC1090
  source "$profile"
}

validate_shell_sources() {
  bash -n "$ROOT_DIR/prepare_aspire4310_macos.sh"
  SHELL_SYNTAX_STATUS="PASS"
  if have_cmd shellcheck; then
    shellcheck "$ROOT_DIR/prepare_aspire4310_macos.sh"
    SHELLCHECK_STATUS="PASS"
  else
    SHELLCHECK_STATUS="NOT AVAILABLE (optional)"
  fi
  if have_cmd shfmt; then
    if shfmt -d "$ROOT_DIR/prepare_aspire4310_macos.sh" >/dev/null; then
      SHFMT_STATUS="PASS"
    else
      SHFMT_STATUS="WARN: formatting diff"
    fi
  else
    SHFMT_STATUS="NOT AVAILABLE (optional)"
  fi
}

validate_plists() {
  local root="$1" plist count=0
  while IFS= read -r plist; do
    [[ -n "$plist" ]] || continue
    python3 - "$plist" <<'PY' || die "Invalid plist: $plist"
import plistlib,sys
with open(sys.argv[1], 'rb') as handle:
    plistlib.load(handle)
PY
    if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] && have_cmd plutil; then
      plutil -lint "$plist" >/dev/null || die "Apple plutil rejected plist: $plist"
    fi
    count=$((count + 1))
  done < <(find "$root" -type f -name '*.plist' -print | LC_ALL=C sort)
  (( count > 0 )) || die "No plist files found for validation under $root"
  printf '%s\n' "$count"
}

resolve_oc_arch() {
  case "$OC_ARCH" in
    auto)
      if [[ "$KERNEL_ARCH" == "i386" ]]; then
        OC_ARCH_DIR="IA32"; OC_ARCH_NAME="IA32"; OC_KERNEL_ARCH="i386"
      else
        OC_ARCH_DIR="X64"; OC_ARCH_NAME="X64"; OC_KERNEL_ARCH="x86_64"
      fi
      ;;
    x64)
      [[ "$OS_PROFILE" != "leopard" ]] \
        || die "Leopard 10.5 i386 requires IA32 OpenCore/OpenDuet; use --oc-arch auto or ia32."
      OC_ARCH_DIR="X64"; OC_ARCH_NAME="X64"; OC_KERNEL_ARCH="x86_64"
      ;;
    ia32) OC_ARCH_DIR="IA32"; OC_ARCH_NAME="IA32"; OC_KERNEL_ARCH="i386" ;;
    *) die "Invalid --oc-arch: $OC_ARCH" ;;
  esac
}

select_hfs_driver() {
  local destination="$1"
  case "$HFS_DRIVER:$OC_ARCH_NAME" in
    auto:X64|legacy:X64)
      HFS_SELECTED="HfsPlusLegacy.efi"
      cp -p "$DOWNLOADS_DIR/$HFS_LEGACY_FILE" "$destination/$HFS_SELECTED"
      ;;
    auto:IA32|32:IA32)
      HFS_SELECTED="HfsPlus32.efi"
      cp -p "$DOWNLOADS_DIR/$HFS_32_FILE" "$destination/$HFS_SELECTED"
      ;;
    openhfs:*)
      HFS_SELECTED="OpenHfsPlus.efi"
      cp -p "$OC_CACHE_ROOT/$OC_ARCH_DIR/EFI/OC/Drivers/OpenHfsPlus.efi" "$destination/$HFS_SELECTED"
      ;;
    legacy:IA32) die "HfsPlusLegacy.efi is X64; use --hfs-driver 32 or openhfs for IA32." ;;
    32:X64) die "HfsPlus32.efi is IA32; use --hfs-driver legacy or openhfs for X64." ;;
    *) die "Invalid --hfs-driver: $HFS_DRIVER" ;;
  esac
  python3 "$INSPECTOR" --binary "$destination/$HFS_SELECTED" --require-arch "$OC_KERNEL_ARCH" --quiet
}

copy_profile_kexts() {
  local destination="$1"
  local manifest="$PROFILES_DIR/$OS_PROFILE/kexts.conf"
  local set_name source_path static_status purpose source_bundle target_bundle executable_name
  while IFS=$'\t' read -r set_name source_path static_status purpose; do
    [[ -n "$set_name" && "$set_name" != \#* ]] || continue
    case "$set_name" in
      smc) ;;
      minimal) [[ "$KEXT_SET" != "smc" ]] || continue ;;
      full) [[ "$KEXT_SET" == "full" ]] || continue ;;
      sata) [[ "$SATA_MODE" == "injected" ]] || continue ;;
      *) continue ;;
    esac
    source_bundle="$LEGACY_KEXTS_ROOT/$source_path"
    [[ -d "$source_bundle" ]] || die "Manifest kext is missing: $source_bundle"
    target_bundle="$destination/$(basename "$source_bundle")"
    [[ ! -e "$target_bundle" ]] || die "Kext basename collision: $target_bundle"
    copy_tree "$source_bundle" "$target_bundle"
    if python3 - "$target_bundle/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f:d=plistlib.load(f)
raise SystemExit(0 if d.get('CFBundleExecutable') else 1)
PY
    then
      python3 "$INSPECTOR" --kext "$target_bundle" --require-arch i386 --quiet
      executable_name="$(python3 - "$target_bundle/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f:d=plistlib.load(f)
print(d.get('CFBundleExecutable',''))
PY
)"
      file "$target_bundle/Contents/MacOS/$executable_name" >/dev/null
      if have_cmd lipo; then lipo -archs "$target_bundle/Contents/MacOS/$executable_name" >/dev/null; fi
    else
      python3 "$INSPECTOR" --kext "$target_bundle" --quiet >/dev/null
    fi
    log "Enabled kext candidate: $(basename "$target_bundle") [$static_status] — $purpose"
  done <"$manifest"
}

resolve_runtime_profile() {
  case "$RUNTIME_PROFILE" in
    auto)
      if [[ "$OS_PROFILE" == "leopard" ]]; then
        RUNTIME_PROFILE_RESOLVED="off"
      else
        RUNTIME_PROFILE_RESOLVED="modern"
      fi
      ;;
    off|legacy|modern) RUNTIME_PROFILE_RESOLVED="$RUNTIME_PROFILE" ;;
    *) die "--runtime must be auto, off, legacy, or modern" ;;
  esac
}

copy_custom_kernels() {
  local destination="$1"
  local source_dir="$INPUT_DIR/kernels/$OS_PROFILE"
  local name source found=0
  mkdir -p "$destination"
  for name in kernel kernelcache prelinkedkernel; do
    source="$source_dir/$name"
    [[ -s "$source" ]] || continue
    if python3 "$INSPECTOR" --binary "$source" --require-arch i386 --quiet; then
      cp -p "$source" "$destination/$name"
      found=$((found + 1))
    else
      warn "Rejected custom kernel artifact without a confirmed i386 slice: $source"
    fi
  done
  (( found > 0 )) || die "--kernel custom requested, but no verified i386 kernel artifacts were found in $source_dir"
}

custom_kernel_available() {
  local name
  for name in kernel kernelcache prelinkedkernel; do
    [[ -s "$INPUT_DIR/kernels/$OS_PROFILE/$name" ]] && return 0
  done
  return 1
}

collect_kext_arguments() {
  local oc_root="$1"
  find "$oc_root/Kexts" -type d -name '*.kext' -print 2>/dev/null \
    | sed "s#^$oc_root/Kexts/##" | LC_ALL=C sort
}

collect_acpi_arguments() {
  local source_dir="$INPUT_DIR/acpi"
  [[ "$ACPI_MODE" == "patched" ]] || return 0
  find "$source_dir" -maxdepth 1 -type f -name '*.aml' -print 2>/dev/null | LC_ALL=C sort
}

ocvalidate_path() {
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) printf '%s\n' "$OC_CACHE_ROOT/Utilities/ocvalidate/ocvalidate" ;;
    Linux) printf '%s\n' "$OC_CACHE_ROOT/Utilities/ocvalidate/ocvalidate.linux" ;;
    *) return 1 ;;
  esac
}

write_build_report() {
  local build_root="$1" kernel_variant="$2" validation="$3"
  local bundle bundle_id version architectures minimum_os digest static_status kernel_file
  detect_host
  cat >"$build_root/BUILD_REPORT.md" <<EOF
# Aspire 4310 build report

Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

## Host

- OS: $HOST_PRODUCT_NAME $HOST_VERSION ($HOST_BUILD)
- Architecture: $HOST_ARCH
- CPU: $HOST_CPU_BRAND
- Status: $HOST_STATUS

## Target

- Model: $TARGET_MODEL
- CPU: $TARGET_CPU (Intel 64 and SSSE3 confirmed; physical CPUID still to collect)
- Chipset/GPU: $TARGET_CHIPSET / $TARGET_GPU

## OS and bootloader

- Profile: $OS_NAME $OS_RANGE
- Target final version: $OS_FINAL
- OpenCore: $OC_VERSION $OC_VARIANT
- OcBinaryData commit: $OCBINARYDATA_SHA
- Legacy-Kexts candidate commit: $LEGACY_KEXTS_SHA
- OpenDuet: $OC_ARCH_NAME
- HFS driver: $HFS_SELECTED
- Kernel profile: $kernel_variant
- KernelArch: i386
- KernelCache: Auto
- CustomKernel: $([[ "$kernel_variant" == custom ]] && printf true || printf false)
- Runtime memory profile: $RUNTIME_PROFILE_RESOLVED
- Boot preset: $BOOT_PRESET
- Kext set: $KEXT_SET
- SATA: $SATA_MODE
- ACPI: $ACPI_MODE
- Duplicate APIC: $APIC_MODE

## Kexts

Every enabled executable was statically checked for an i386 slice. Plist-only injectors are
identified separately; static compatibility is not a claim of runtime functionality.

| Bundle | Bundle ID | Version | Architectures | Minimum OS | SHA-256 | Status |
|---|---|---:|---|---|---|---|
EOF
  while IFS=$'\t' read -r bundle bundle_id version architectures minimum_os digest static_status; do
    [[ "$bundle" != "bundle" ]] || continue
    # Literal Markdown backticks are intentional.
    # shellcheck disable=SC2016
    printf '| `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | %s |\n' \
      "$bundle" "$bundle_id" "$version" "$architectures" "$minimum_os" "$digest" "$static_status" \
      >>"$build_root/BUILD_REPORT.md"
  done <"$build_root/KEXT_REPORT.tsv"

  cat >>"$build_root/BUILD_REPORT.md" <<EOF

## Kernel artifacts

EOF
  if [[ "$kernel_variant" == "custom" ]]; then
    printf '| Artifact | SHA-256 |\n|---|---|\n' >>"$build_root/BUILD_REPORT.md"
    while IFS= read -r kernel_file; do
      # Literal Markdown backticks are intentional.
      # shellcheck disable=SC2016
      printf '| `%s` | `%s` |\n' "$(basename "$kernel_file")" "$(sha256_file "$kernel_file")" \
        >>"$build_root/BUILD_REPORT.md"
    done < <(find "$build_root/ESP/Kernels" -maxdepth 1 -type f -print | LC_ALL=C sort)
  else
    printf 'Vanilla mode: no kernel was copied or replaced; the retail source remains unmodified.\n' \
      >>"$build_root/BUILD_REPORT.md"
  fi

  cat >>"$build_root/BUILD_REPORT.md" <<EOF

## Known unresolved hardware

BCM5787M Ethernet, exact Wi-Fi PCI ID, ALC268 codec confirmation, battery ACPI,
Bluetooth, FireWire, webcam and modem remain post-install/runtime work.

## Validation

$validation

- bash -n: $SHELL_SYNTAX_STATUS
- shellcheck: $SHELLCHECK_STATUS
- shfmt -d: $SHFMT_STATUS
EOF
  cp -p "$build_root/BUILD_REPORT.md" "$ROOT_DIR/BUILD_REPORT.md"
}

build_opencore_variant() {
  local kernel_variant="$1"
  local build_root="$OUTPUT_DIR/$OS_PROFILE/opencore-$kernel_variant"
  local esp="$build_root/ESP" oc_root="$build_root/ESP/EFI/OC"
  local arch_source="$OC_CACHE_ROOT/$OC_ARCH_DIR"
  local validation=""
  local item relative validator plist_count inspection
  local -a config_args

  safe_remove_generated "$build_root"
  mkdir -p "$esp/EFI/BOOT" "$oc_root/ACPI" "$oc_root/Drivers" "$oc_root/Kexts" "$oc_root/Tools" "$build_root/OpenDuet"
  cp -p "$arch_source/EFI/BOOT/"*.efi "$esp/EFI/BOOT/"
  printf '%s' 'Disabled' >"$esp/EFI/BOOT/.contentVisibility"
  cp -p "$arch_source/EFI/OC/OpenCore.efi" "$oc_root/OpenCore.efi"
  if [[ "$RUNTIME_PROFILE_RESOLVED" != "off" ]]; then
    cp -p "$arch_source/EFI/OC/Drivers/OpenRuntime.efi" "$oc_root/Drivers/OpenRuntime.efi"
  fi
  cp -p "$arch_source/EFI/OC/Drivers/Ps2KeyboardDxe.efi" "$oc_root/Drivers/Ps2KeyboardDxe.efi"
  cp -p "$arch_source/EFI/OC/Drivers/Ps2MouseDxe.efi" "$oc_root/Drivers/Ps2MouseDxe.efi"
  select_hfs_driver "$oc_root/Drivers"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/boot$OC_ARCH_NAME" "$esp/boot"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/BootInstall_${OC_ARCH_NAME}.tool" "$build_root/OpenDuet/"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/BootInstallBase.sh" "$build_root/OpenDuet/"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/boot0" "$build_root/OpenDuet/"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/boot1f32" "$build_root/OpenDuet/"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/boot$OC_ARCH_NAME" "$build_root/OpenDuet/"
  cp -p "$OC_CACHE_ROOT/Utilities/LegacyBoot/README.md" "$build_root/OpenDuet/"

  copy_profile_kexts "$oc_root/Kexts"
  if [[ "$ACPI_MODE" == "patched" ]]; then
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      [[ -s "$item" ]] || die "Empty ACPI file: $item"
      cp -p "$item" "$oc_root/ACPI/$(basename "$item")"
    done < <(collect_acpi_arguments)
    [[ -n "$(find "$oc_root/ACPI" -type f -name '*.aml' -print -quit)" ]] \
      || die "--acpi patched requested, but input/acpi contains no AML files."
  fi
  if [[ "$kernel_variant" == "custom" ]]; then
    copy_custom_kernels "$esp/Kernels"
  fi

  config_args=(
    --sample "$OC_CACHE_ROOT/Docs/Sample.plist"
    --output "$oc_root/config.plist"
    --oc-root "$oc_root"
    --os "$OS_PROFILE"
    --kernel "$kernel_variant"
    --boot-preset "$BOOT_PRESET"
    --runtime-profile "$RUNTIME_PROFILE_RESOLVED"
    --oc-version "$OC_VERSION"
  )
  if [[ "$RUNTIME_PROFILE_RESOLVED" != "off" ]]; then
    config_args+=(--driver OpenRuntime.efi)
  fi
  config_args+=(
    --driver "$HFS_SELECTED"
    --driver Ps2KeyboardDxe.efi
    --driver Ps2MouseDxe.efi
  )
  if [[ "$APIC_MODE" == "drop-duplicate" ]]; then
    config_args+=(--drop-duplicate-apic)
  fi
  while IFS= read -r relative; do
    [[ -n "$relative" ]] && config_args+=(--kext "$relative")
  done < <(collect_kext_arguments "$oc_root")
  while IFS= read -r item; do
    [[ -n "$item" ]] && config_args+=(--acpi "$(basename "$item")")
  done < <(collect_acpi_arguments)
  python3 "$CONFIG_GENERATOR" "${config_args[@]}"
  python3 "$TREE_VALIDATOR" "$oc_root/config.plist"

  validator="$(ocvalidate_path || true)"
  if [[ -n "$validator" && -f "$validator" ]]; then
    chmod +x "$validator" 2>/dev/null || true
    "$validator" "$oc_root/config.plist"
    validation="- EFI references/dependencies: PASS"$'\n'"- ocvalidate $OC_VERSION: PASS"
  else
    validation="- EFI references/dependencies: PASS"$'\n''- ocvalidate: NOT RUN on this host'
  fi
  plist_count="$(validate_plists "$build_root")"
  if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] && have_cmd plutil; then
    validation="${validation}"$'\n'"- plistlib + Apple plutil ($plist_count files): PASS"
  else
    validation="${validation}"$'\n'"- plistlib ($plist_count files): PASS"
  fi

  printf 'bundle\tbundle_id\tversion\tarchitectures\tminimum_os\tsha256\tstatus\n' >"$build_root/KEXT_REPORT.tsv"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    inspection="$(python3 "$INSPECTOR" --kext "$oc_root/Kexts/$item" --require-arch i386)"
    printf '%s\n' "$inspection" | python3 -c \
      'import json,sys; d=json.load(sys.stdin); status="STATIC_I386_PASS; RUNTIME_NOT_TESTED" if d["executable"] else "PLIST_ONLY_UNVERIFIED; RUNTIME_NOT_TESTED"; print("%s\t%s\t%s\t%s\t%s\t%s\t%s" % (d["path"].split("/Kexts/",1)[-1],d["bundle_id"],d["version"],",".join(d["architectures"]) or "PLIST_ONLY",d["minimum_os"],d["sha256"],status))' \
      >>"$build_root/KEXT_REPORT.tsv"
  done < <(collect_kext_arguments "$oc_root")
  write_build_report "$build_root" "$kernel_variant" "$validation"
  log "Built and validated: $build_root"
}

find_chameleon_i386() {
  find "$CACHE_DIR/chameleon" "$INPUT_DIR/chameleon" "$DOWNLOADS_DIR" \
    -type f -path '*/i386/boot0' -print 2>/dev/null | head -n 1 | sed 's#/boot0$##'
}

prepare_chameleon_manual_archive() {
  local archive=""
  local destination="$CACHE_DIR/chameleon/manual"
  local top
  [[ -n "$(find_chameleon_i386 || true)" ]] && return 0
  for archive in "$INPUT_DIR/chameleon/chameleon-binaries.tar.gz" "$DOWNLOADS_DIR/chameleon-binaries.tar.gz"; do
    [[ -s "$archive" ]] && break
    archive=""
  done
  [[ -n "$archive" ]] || return 1
  [[ ! -e "$destination" ]] || die "Incomplete Chameleon cache exists: $destination"
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aspire4310.chameleon.XXXXXX")"
  mkdir -p "$TEMP_DIR/extract"
  tar -xzf "$archive" -C "$TEMP_DIR/extract"
  top="$(find "$TEMP_DIR/extract" -type f -path '*/i386/boot0' -print -quit | sed 's#/i386/boot0$##')"
  [[ -n "$top" ]] || die "Manual Chameleon archive lacks i386/boot0."
  mkdir -p "$(dirname "$destination")"
  mv -- "$top" "$destination"
}

write_chameleon_plists() {
  local extra="$1"
  cat >"$extra/com.apple.Boot.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Timeout</key><string>8</string>
<key>Kernel Flags</key><string>-v arch=i386 cpus=1 keepsyms=1 debug=0x100</string>
<key>GraphicsEnabler</key><string>No</string>
</dict></plist>
EOF
  cat >"$extra/smbios.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>SMproductname</key><string>MacBook2,1</string>
<key>SMfamily</key><string>MacBook</string>
<key>SMmanufacturer</key><string>Apple Inc.</string>
</dict></plist>
EOF
}

build_chameleon() {
  local build_root="$OUTPUT_DIR/$OS_PROFILE/chameleon"
  local i386
  prepare_chameleon_manual_archive || die "Chameleon is lost-media fallback only. Supply input/chameleon/chameleon-binaries.tar.gz with i386/boot0, boot1h and boot."
  i386="$(find_chameleon_i386)"
  [[ -f "$i386/boot0" && -f "$i386/boot1h" && -f "$i386/boot" ]] || die "Incomplete Chameleon i386 directory: $i386"
  safe_remove_generated "$build_root"
  mkdir -p "$build_root/Extra/Extensions" "$build_root/i386"
  cp -p "$i386/boot0" "$i386/boot1h" "$i386/boot" "$build_root/i386/"
  cp -p "$i386/boot" "$build_root/boot"
  write_chameleon_plists "$build_root/Extra"
  copy_profile_kexts "$build_root/Extra/Extensions"
  validate_plists "$build_root" >/dev/null
  log "Built Chameleon fallback staging tree: $build_root"
}

run_build() {
  load_os_profile
  validate_shell_sources
  resolve_oc_arch
  resolve_runtime_profile
  load_current_sources
  case "$BOOTLOADER" in
    auto|opencore)
      case "$KERNEL_MODE" in
        vanilla) build_opencore_variant vanilla ;;
        custom) build_opencore_variant custom ;;
        auto)
          build_opencore_variant vanilla
          if custom_kernel_available; then build_opencore_variant custom; else log "No optional custom kernel supplied; vanilla profile preserved."; fi
          ;;
      esac
      if [[ "$BOOTLOADER" == "auto" ]]; then
        if prepare_chameleon_manual_archive; then build_chameleon; else warn "No verified Chameleon archive; auto build contains OpenCore only."; fi
      fi
      ;;
    chameleon) build_chameleon ;;
    *) die "Invalid --bootloader: $BOOTLOADER" ;;
  esac
}

validate_disk_identifier() {
  [[ "$1" =~ ^/dev/disk[0-9]+$ ]] || die "Whole-disk identifier required, e.g. /dev/disk2 (not a slice)."
}

validate_slice_identifier() {
  [[ "$1" =~ ^/dev/disk[0-9]+s[0-9]+$ ]] || die "Partition identifier required, e.g. /dev/disk2s1."
}

disk_partition_slices() {
  diskutil list "$1" | awk '/[0-9]+:[[:space:]]/ {print $NF}' \
    | grep -E '^disk[0-9]+s[0-9]+$' | sed 's#^#/dev/#'
}

disk_contains_protected_volume() {
  local disk="$1" slice mount_point details
  while IFS= read -r slice; do
    details="$(diskutil info "$slice" 2>/dev/null || true)"
    mount_point="$(printf '%s\n' "$details" | awk -F': *' '/Mount Point/ {print $2; exit}')"
    [[ -n "$mount_point" && "$mount_point" != "Not mounted" ]] || continue
    is_protected_volume "$mount_point" && return 0
  done < <(disk_partition_slices "$disk")
  return 1
}

assert_preserve_layout() {
  local slices partition_count boot_info
  validate_slice_identifier "$BOOT_SLICE"
  validate_slice_identifier "$INSTALLER_SLICE"
  [[ "$BOOT_SLICE" == "${DISK}s1" ]] \
    || die "Preserve layout requires the OpenDuet boot partition to be ${DISK}s1."
  [[ "$INSTALLER_SLICE" == "${DISK}s2" ]] \
    || die "Preserve layout requires the replaceable installer partition to be ${DISK}s2."
  [[ "$BOOT_SLICE" != "$INSTALLER_SLICE" ]] || die "Boot and installer slices must differ."

  diskutil info "$BOOT_SLICE" >/dev/null || die "Boot slice does not exist: $BOOT_SLICE"
  diskutil info "$INSTALLER_SLICE" >/dev/null || die "Installer slice does not exist: $INSTALLER_SLICE"
  slices="$(disk_partition_slices "$DISK")"
  partition_count="$(printf '%s\n' "$slices" | awk 'NF {count++} END {print count+0}')"
  [[ "$partition_count" == "2" ]] \
    || die "Preserve layout is intentionally limited to exactly two partitions; found $partition_count on $DISK."
  boot_info="$(diskutil info "$BOOT_SLICE")"
  printf '%s\n' "$boot_info" | grep -Eq \
    'File System Personality:.*(MS-DOS FAT32|FAT32)|Type \(Bundle\):.*msdos|EFI System Partition' \
    || die "The preserved first partition must be FAT32/EFI: $BOOT_SLICE"
}

assert_boot_slice() {
  local boot_info
  validate_slice_identifier "$BOOT_SLICE"
  [[ "$BOOT_SLICE" == "${DISK}s1" ]] \
    || die "EFI update requires the OpenDuet boot partition to be ${DISK}s1."
  boot_info="$(diskutil info "$BOOT_SLICE")" || die "Boot slice does not exist: $BOOT_SLICE"
  printf '%s\n' "$boot_info" | grep -Eq \
    'File System Personality:.*(MS-DOS FAT32|FAT32)|Type \(Bundle\):.*msdos|EFI System Partition' \
    || die "The OpenDuet boot partition must be FAT32/EFI: $BOOT_SLICE"
}

assert_safe_target_disk() {
  local disk="$1" info internal
  info="$(diskutil info "$disk")" || die "diskutil info failed for $disk"
  printf '%s\n' "$info"
  printf '\nCurrent partition map for %s:\n' "$disk"
  diskutil list "$disk"
  disk_contains_protected_volume "$disk" && die "$disk contains a volume protected by --protect-volume."
  internal="$(printf '%s\n' "$info" | awk -F': *' '/Internal:/ {print $2; exit}')"
  if [[ "$internal" == "Yes" && "$ALLOW_INTERNAL" -ne 1 ]]; then
    die "$disk is Internal: Yes. Refusing without --allow-internal."
  fi
  if ! printf '%s\n' "$info" | grep -Eq 'External:[[:space:]]*Yes|Device Location:[[:space:]]*External|Removable Media:[[:space:]]*Removable'; then
    [[ "$ALLOW_INTERNAL" -eq 1 ]] || die "$disk is not clearly external/removable."
  fi
}

run_list_disks() {
  require_macos_build_host
  diskutil list
  printf '\nNo disk was modified. Verify the whole-disk identifier and every partition before continuing.\n'
}

confirm_erase() {
  local answer
  printf '\nType exactly: ERASE %s\n> ' "$DISK"
  IFS= read -r answer
  [[ "$answer" == "ERASE $DISK" ]] || die "Confirmation mismatch; nothing was erased."
}

confirm_preserve_replace() {
  local answer expected
  expected="REPLACE $INSTALLER_SLICE AND UPDATE $BOOT_SLICE"
  printf '\nThe partition map and partition 1 will be preserved.\n'
  printf 'All contents of %s will be erased; EFI/OpenDuet on %s will be replaced.\n' \
    "$INSTALLER_SLICE" "$BOOT_SLICE"
  printf 'Type exactly: %s\n> ' "$expected"
  IFS= read -r answer
  [[ "$answer" == "$expected" ]] || die "Confirmation mismatch; nothing was erased."
}

confirm_efi_update() {
  local answer expected
  expected="UPDATE $BOOT_SLICE ON $DISK"
  printf '\nThe partition map and installer partition will not be changed.\n'
  printf 'EFI/OpenDuet files on %s will be backed up and replaced.\n' "$BOOT_SLICE"
  printf 'Type exactly: %s\n> ' "$expected"
  IFS= read -r answer
  [[ "$answer" == "$expected" ]] || die "Confirmation mismatch; nothing was changed."
}

mount_boot_slice_writable() {
  local slice="$1" info mount_point read_only
  info="$(diskutil info "$slice")" || die "Cannot inspect boot slice: $slice"
  mount_point="$(printf '%s\n' "$info" | awk -F': *' '/Mount Point/ {print $2; exit}')"
  read_only="$(printf '%s\n' "$info" | awk -F': *' '/Volume Read-Only/ {print $2; exit}')"
  if [[ -n "$mount_point" && "$mount_point" != "Not mounted" && "$read_only" == "Yes" ]]; then
    sudo diskutil unmount "$slice" >/dev/null
    mount_point=""
  fi
  if [[ -z "$mount_point" || "$mount_point" == "Not mounted" ]]; then
    sudo diskutil mount "$slice" >/dev/null
  fi
  info="$(diskutil info "$slice")" || die "Cannot rediscover mounted boot slice: $slice"
  mount_point="$(printf '%s\n' "$info" | awk -F': *' '/Mount Point/ {print $2; exit}')"
  read_only="$(printf '%s\n' "$info" | awk -F': *' '/Volume Read-Only/ {print $2; exit}')"
  [[ -d "$mount_point" && "$read_only" != "Yes" ]] \
    || die "Boot slice is not mounted read-write: $slice"
  printf '%s\n' "$mount_point"
}

replace_boot_files() {
  local efi_mount="$1" build_root="$2" backup_dir had_efi=0
  case "$efi_mount" in
    /Volumes/?*) ;;
    *) die "Refusing EFI replacement at unexpected mount point: $efi_mount" ;;
  esac
  backup_dir="$ROOT_DIR/backup/usb-$(date '+%Y%m%d-%H%M%S')-$(basename "$DISK")"
  if [[ -d "$efi_mount/EFI" || -f "$efi_mount/boot" ]]; then
    mkdir -p "$backup_dir"
    if [[ -d "$efi_mount/EFI" ]]; then
      ditto "$efi_mount/EFI" "$backup_dir/EFI"
      [[ -d "$backup_dir/EFI" ]] || die "Existing EFI backup failed: $backup_dir"
      had_efi=1
    fi
    if [[ -f "$efi_mount/boot" ]]; then
      cp -p "$efi_mount/boot" "$backup_dir/boot"
    fi
    if (( had_efi == 1 )); then
      sudo rm -rf -- "$efi_mount/EFI"
    fi
    log "Existing boot files backed up outside the USB: $backup_dir"
  fi
  sudo ditto "$build_root/ESP/EFI" "$efi_mount/EFI"
  sudo cp -p "$build_root/ESP/boot" "$efi_mount/boot"
  [[ -f "$efi_mount/EFI/OC/config.plist" && -f "$efi_mount/boot" ]] \
    || die "New EFI/OpenDuet copy could not be verified."
}

auto_retail_source() {
  local candidate
  case "$OS_PROFILE" in
    leopard)
      for candidate in "$INPUT_DIR/Leopard-Retail.dmg" "$INPUT_DIR/Leopard-Retail.iso"; do [[ -e "$candidate" ]] && { printf '%s\n' "$candidate"; return; }; done
      ;;
    snowleopard)
      for candidate in "$INPUT_DIR/SnowLeopard-Retail.dmg" "$INPUT_DIR/SnowLeopard-Retail.iso"; do [[ -e "$candidate" ]] && { printf '%s\n' "$candidate"; return; }; done
      ;;
  esac
}

attach_retail_readonly() {
  local image="$1" output volume
  output="$(hdiutil attach -nobrowse -readonly "$image")"
  ATTACHED_IMAGE_DEVICE="$(printf '%s\n' "$output" | awk '/^\/dev\// {print $1; exit}')"
  volume="$(printf '%s\n' "$output" | awk '/\/Volumes\// {print substr($0,index($0,"/Volumes/")); exit}')"
  [[ -n "$volume" ]] || die "Could not identify read-only mounted retail volume."
  ATTACHED_RETAIL_VOLUME="$volume"
}

restore_retail() {
  local source="$1" target="$2"
  local restore_source="$source" lower
  lower="$(printf '%s' "$source" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.dmg|*.iso)
      attach_retail_readonly "$source"
      restore_source="$ATTACHED_RETAIL_VOLUME"
      ;;
  esac
  if ! sudo asr restore --source "$restore_source" --target "$target" --erase --noprompt; then
    case "$lower" in
      *.dmg|*.iso)
        warn "First asr restore failed; image-scanning the user-provided source and retrying."
        sudo asr imagescan --source "$source"
        sudo asr restore --source "$source" --target "$target" --erase --noprompt
        ;;
      *) die "asr restore failed for mounted source: $source" ;;
    esac
  fi
}

run_make_usb() {
  local build_root deploy_variant esp_slice installer_slice efi_mount volume_uuid disk_number boot_tool
  require_macos_build_host
  validate_disk_identifier "$DISK"
  [[ -n "$RETAIL" ]] || RETAIL="$(auto_retail_source || true)"
  [[ -n "$RETAIL" && -e "$RETAIL" ]] || die "Retail source not found; pass --retail or place the documented image in input/."
  [[ "$BOOTLOADER" == auto || "$BOOTLOADER" == opencore ]] || die "Automated GPT USB deployment currently supports the OpenCore backend; Chameleon output remains a manual fallback."
  load_os_profile
  resolve_oc_arch
  load_current_sources
  run_build
  deploy_variant="vanilla"
  [[ "$KERNEL_MODE" == "custom" ]] && deploy_variant="custom"
  build_root="$OUTPUT_DIR/$OS_PROFILE/opencore-$deploy_variant"
  [[ -f "$build_root/ESP/EFI/OC/config.plist" ]] || die "Expected deployment build is missing: $build_root"
  assert_safe_target_disk "$DISK"
  if [[ "$USB_LAYOUT" == "preserve" ]]; then
    [[ -n "$BOOT_SLICE" && -n "$INSTALLER_SLICE" ]] \
      || die "--layout preserve requires --boot-slice and --installer-slice."
    assert_preserve_layout
  else
    [[ -z "$BOOT_SLICE" && -z "$INSTALLER_SLICE" ]] \
      || die "--boot-slice/--installer-slice are valid only with --layout preserve."
  fi
  if (( DRY_RUN == 1 )); then
    if [[ "$USB_LAYOUT" == "preserve" ]]; then
      cat <<EOF
DRY RUN — no disk writes were performed.
Would preserve the GPT map and $BOOT_SLICE, then:
  sudo asr restore --source "$RETAIL" --target "$INSTALLER_SLICE" --erase --noprompt
  back up and replace EFI files on $BOOT_SLICE
  update OpenDuet MBR/PBR using OpenCore $OC_VERSION BootInstall_${OC_ARCH_NAME}.tool
EOF
    else
      cat <<EOF
DRY RUN — no disk writes were performed.
Would run:
  diskutil partitionDisk "$DISK" GPT JHFS+ INSTALLER R
  sudo asr restore --source "$RETAIL" --target "${DISK}s2" --erase --noprompt
  copy "$build_root/ESP/EFI" to the mounted EFI partition
  run matching OpenCore $OC_VERSION Utilities/LegacyBoot/BootInstall_${OC_ARCH_NAME}.tool for $DISK
EOF
    fi
    return 0
  fi
  if [[ "$USB_LAYOUT" == "preserve" ]]; then
    confirm_preserve_replace
    esp_slice="$BOOT_SLICE"
    installer_slice="$INSTALLER_SLICE"
  else
    confirm_erase
    sudo diskutil partitionDisk "$DISK" GPT JHFS+ INSTALLER R
    esp_slice="${DISK}s1"
    installer_slice="${DISK}s2"
  fi
  restore_retail "$RETAIL" "$installer_slice"
  volume_uuid="$(diskutil info -plist "$installer_slice" | plutil -extract VolumeUUID raw -o - - 2>/dev/null || true)"
  [[ -n "$volume_uuid" ]] || die "Restore completed, but installer VolumeUUID could not be rediscovered."
  diskutil info "$volume_uuid" >/dev/null || die "Restored installer could not be re-identified by UUID $volume_uuid."
  sudo diskutil mount "$esp_slice" >/dev/null
  efi_mount="$(diskutil info "$esp_slice" | awk -F': *' '/Mount Point/ {print $2; exit}')"
  [[ -d "$efi_mount" ]] || die "EFI partition did not mount."
  replace_boot_files "$efi_mount" "$build_root"
  disk_number="${DISK#/dev/disk}"
  boot_tool="$OC_CACHE_ROOT/Utilities/LegacyBoot/BootInstall_${OC_ARCH_NAME}.tool"
  chmod +x "$boot_tool" "$OC_CACHE_ROOT/Utilities/LegacyBoot/BootInstallBase.sh"
  printf '%s\n' "$disk_number" | "$boot_tool"
  sync
  log "USB prepared. Installer UUID: $volume_uuid. Run --verify-usb --disk $DISK before moving it to the Acer."
}

run_update_efi() {
  local build_root deploy_variant efi_mount disk_number boot_tool
  require_macos_build_host
  validate_disk_identifier "$DISK"
  [[ -n "$BOOT_SLICE" ]] || die "--update-efi requires --boot-slice /dev/diskXs1"
  [[ -z "$INSTALLER_SLICE" ]] || die "--update-efi does not accept --installer-slice"
  [[ "$BOOTLOADER" == auto || "$BOOTLOADER" == opencore ]] \
    || die "--update-efi currently supports only OpenCore/OpenDuet"
  run_build
  deploy_variant="vanilla"
  [[ "$KERNEL_MODE" == "custom" ]] && deploy_variant="custom"
  build_root="$OUTPUT_DIR/$OS_PROFILE/opencore-$deploy_variant"
  [[ -f "$build_root/ESP/EFI/OC/config.plist" ]] \
    || die "Expected deployment build is missing: $build_root"
  assert_safe_target_disk "$DISK"
  assert_boot_slice
  if (( DRY_RUN == 1 )); then
    cat <<EOF
DRY RUN — no disk writes were performed.
Would preserve the partition map and every non-EFI partition, then:
  back up and replace EFI/OpenDuet files on $BOOT_SLICE
  update OpenDuet MBR/PBR using OpenCore $OC_VERSION BootInstall_${OC_ARCH_NAME}.tool
EOF
    return 0
  fi
  confirm_efi_update
  efi_mount="$(mount_boot_slice_writable "$BOOT_SLICE")"
  replace_boot_files "$efi_mount" "$build_root"
  disk_number="${DISK#/dev/disk}"
  boot_tool="$OC_CACHE_ROOT/Utilities/LegacyBoot/BootInstall_${OC_ARCH_NAME}.tool"
  chmod +x "$boot_tool" "$OC_CACHE_ROOT/Utilities/LegacyBoot/BootInstallBase.sh"
  printf '%s\n' "$disk_number" | "$boot_tool"
  sync
  log "EFI/OpenDuet updated; installer partition was not modified. Run --verify-usb --disk $DISK."
}

run_verify_usb() {
  local info slice mount_point found=0
  require_macos_build_host
  if [[ -n "$DISK" ]]; then
    validate_disk_identifier "$DISK"
    info="$(diskutil info "$DISK")" || die "Cannot inspect $DISK"
    printf '%s\n' "$info"
    disk_contains_protected_volume "$DISK" && warn "$DISK contains a protected volume; verification remains read-only."
    while IFS= read -r slice; do
      mount_point="$(diskutil info "$slice" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}')"
      if [[ -n "$mount_point" && "$mount_point" != "Not mounted" ]]; then
        if is_protected_volume "$mount_point"; then
          printf '\nProtected volume skipped without reading: %s\n' "$mount_point"
          continue
        fi
        audit_volume "$mount_point"
        found=$((found + 1))
      fi
    done < <(disk_partition_slices "$DISK")
    (( found > 0 )) || warn "No mounted partitions were available for file-level verification; nothing was mounted automatically."
  else
    audit_volume "$AUDIT_VOLUME"
  fi
}

set_mode() {
  [[ -z "$MODE" || "$MODE" == "$1" ]] || die "Choose exactly one operation."
  MODE="$1"
}

need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }

while (($#)); do
  case "$1" in
    --doctor) set_mode doctor ;;
    --audit) set_mode audit ;;
    --download|--download-only) set_mode download ;;
    --build) set_mode build ;;
    --list-disks) set_mode list-disks ;;
    --make-usb) set_mode make-usb ;;
    --update-efi) set_mode update-efi ;;
    --verify-usb) set_mode verify-usb ;;
    --os) need_value "$@"; shift; OS_PROFILE="$1" ;;
    --bootloader) need_value "$@"; shift; BOOTLOADER="$1" ;;
    --oc-arch) need_value "$@"; shift; OC_ARCH="$1" ;;
    --hfs-driver) need_value "$@"; shift; HFS_DRIVER="$1" ;;
    --kernel) need_value "$@"; shift; KERNEL_MODE="$1" ;;
    --boot-preset) need_value "$@"; shift; BOOT_PRESET="$1" ;;
    --kext-set) need_value "$@"; shift; KEXT_SET="$1" ;;
    --sata) need_value "$@"; shift; SATA_MODE="$1" ;;
    --acpi) need_value "$@"; shift; ACPI_MODE="$1" ;;
    --apic) need_value "$@"; shift; APIC_MODE="$1" ;;
    --runtime) need_value "$@"; shift; RUNTIME_PROFILE="$1" ;;
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --retail) need_value "$@"; shift; RETAIL="$1" ;;
    --volume) need_value "$@"; shift; AUDIT_VOLUME="$1" ;;
    --layout) need_value "$@"; shift; USB_LAYOUT="$1" ;;
    --boot-slice) need_value "$@"; shift; BOOT_SLICE="$1" ;;
    --installer-slice) need_value "$@"; shift; INSTALLER_SLICE="$1" ;;
    --protect-volume) need_value "$@"; shift; PROTECTED_VOLUMES+=("$1") ;;
    --dry-run) DRY_RUN=1 ;;
    --allow-internal) ALLOW_INTERNAL=1 ;;
    --skip-combo-updates) SKIP_COMBO_UPDATES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

case "$OS_PROFILE" in leopard|snowleopard) ;; *) die "--os must be leopard or snowleopard" ;; esac
case "$KERNEL_MODE" in auto|vanilla|custom) ;; *) die "--kernel must be auto, vanilla, or custom" ;; esac
case "$BOOT_PRESET" in normal|verbose|safe|diagnostic) ;; *) die "Invalid --boot-preset" ;; esac
case "$KEXT_SET" in smc|minimal|full) ;; *) die "--kext-set must be smc, minimal, or full" ;; esac
case "$SATA_MODE" in native|injected) ;; *) die "--sata must be native or injected" ;; esac
case "$ACPI_MODE" in native|patched) ;; *) die "--acpi must be native or patched" ;; esac
case "$APIC_MODE" in native|drop-duplicate) ;; *) die "--apic must be native or drop-duplicate" ;; esac
case "$RUNTIME_PROFILE" in auto|off|legacy|modern) ;; *) die "--runtime must be auto, off, legacy, or modern" ;; esac
case "$USB_LAYOUT" in fresh|preserve) ;; *) die "--layout must be fresh or preserve" ;; esac

case "$MODE" in
  doctor) if ! doctor_host; then exit 1; fi ;;
  audit) run_audit ;;
  download) run_download ;;
  build) run_build ;;
  list-disks) run_list_disks ;;
  make-usb) [[ -n "$DISK" ]] || die "--make-usb requires --disk /dev/diskX"; run_make_usb ;;
  update-efi) [[ -n "$DISK" ]] || die "--update-efi requires --disk /dev/diskX"; run_update_efi ;;
  verify-usb) [[ -n "$DISK" || -n "$AUDIT_VOLUME" ]] || die "Pass --disk or --volume"; run_verify_usb ;;
  "") usage; exit 1 ;;
esac
