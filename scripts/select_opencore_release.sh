#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
DOWNLOADS_DIR="$ROOT_DIR/downloads"
CACHE_DIR="$ROOT_DIR/cache"
CURRENT_SOURCES="$CACHE_DIR/current-sources.env"
MANIFEST="$DOWNLOADS_DIR/manifest.tsv"

VERSION="latest"
VARIANT="DEBUG"
MODE=""

log() { printf '[opencore-select] %s\n' "$*"; }
die() { printf '[opencore-select] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }

usage() {
  cat <<'USAGE'
Select or download an OpenCore release for the shared installer cache.

Usage:
  bash scripts/select_opencore_release.sh --download --version 1.0.2 --variant DEBUG
  bash scripts/select_opencore_release.sh --select-only --version 1.0.2 --variant RELEASE

Options:
  --version latest|X.Y.Z       OpenCore release; default: latest
  --variant DEBUG|RELEASE      release asset variant; default: DEBUG
  --download                   resolve/download/extract, then select
  --select-only                select an already cached release

The archive is kept in downloads/OpenCore-<version>-<variant>.zip and extracted
under cache/opencore/<version>/<variant>. Selection updates only the OC_* fields
in cache/current-sources.env; pinned kext/HFS metadata is preserved.

This helper intentionally validates the IA32/OpenDuet assets used by the current
legacy-laptop profiles. It is compatible with Bash 3.2 so it can also run on the
older Intel macOS hosts used by this project.
USAGE
}

normalize_variant() {
  local value
  value="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  case "$value" in
    DEBUG|RELEASE) printf '%s\n' "$value" ;;
    *) die "--variant must be DEBUG or RELEASE" ;;
  esac
}

while (($#)); do
  case "$1" in
    --version) need_value "$@"; shift; VERSION="$1" ;;
    --variant) need_value "$@"; shift; VARIANT="$(normalize_variant "$1")" ;;
    --download) [[ -z "$MODE" ]] || die "Choose one mode"; MODE="download" ;;
    --select-only) [[ -z "$MODE" ]] || die "Choose one mode"; MODE="select" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$MODE" ]] || die "Choose --download or --select-only"
case "$VARIANT" in DEBUG|RELEASE) ;; *) die "--variant must be DEBUG or RELEASE" ;; esac
if [[ "$VERSION" != latest && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "--version must be 'latest' or a release tag like 1.0.2"
fi

sha256_file() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
  else die "sha256sum or shasum is required"
  fi
}

ensure_manifest() {
  mkdir -p "$DOWNLOADS_DIR"
  if [[ ! -f "$MANIFEST" ]]; then
    printf 'timestamp\tsource\tversion\turl\tfilename\tsha256\tstatus\n' >"$MANIFEST"
  fi
}

record_manifest() {
  local version="$1" url="$2" filename="$3" digest="$4"
  ensure_manifest
  if ! awk -F '\t' -v u="$url" -v f="$filename" -v h="$digest" \
      'NR > 1 && $4 == u && $5 == f && $6 == h && $7 == "VERIFIED" {found=1} END {exit !found}' \
      "$MANIFEST"; then
    printf '%s\tOpenCorePkg\t%s\t%s\t%s\t%s\tVERIFIED\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$version" "$url" "$filename" "$digest" >>"$MANIFEST"
  fi
}

current_value() {
  local key="$1"
  [[ -f "$CURRENT_SOURCES" ]] || return 1
  sed -n "s/^${key}=//p" "$CURRENT_SOURCES" | tail -n 1
}

resolve_release() {
  local requested="$1" variant="$2" api tmp status
  have curl || die "curl is required for --download"
  have python3 || die "python3 is required for --download"
  mkdir -p "$CACHE_DIR"
  tmp="$(mktemp "$CACHE_DIR/opencore-release.XXXXXX.json")"
  if [[ "$requested" == latest ]]; then
    api="https://api.github.com/repos/acidanthera/OpenCorePkg/releases/latest"
  else
    api="https://api.github.com/repos/acidanthera/OpenCorePkg/releases/tags/$requested"
  fi
  if ! curl -fsSL --retry 3 --connect-timeout 20 "$api" -o "$tmp"; then
    rm -f -- "$tmp"
    die "Could not resolve OpenCore release '$requested'"
  fi
  set +e
  python3 - "$tmp" "$variant" <<'PY'
import json, sys
p=json.load(open(sys.argv[1], encoding='utf-8'))
variant=sys.argv[2]
tag=p.get('tag_name','')
name=f'OpenCore-{tag}-{variant}.zip'
for asset in p.get('assets', []):
    if asset.get('name') == name:
        print(tag)
        print(asset.get('browser_download_url',''))
        break
else:
    raise SystemExit(f'asset not found: {name}')
PY
  status=$?
  set -e
  rm -f -- "$tmp"
  (( status == 0 )) || return "$status"
}

extract_archive() {
  local archive="$1" cache_root="$2" staging
  if [[ -f "$cache_root/Docs/Sample.plist" ]]; then return 0; fi
  [[ ! -e "$cache_root" ]] || die "Incomplete OpenCore cache exists: $cache_root"
  staging="${cache_root}.extracting"
  rm -rf -- "$staging"
  mkdir -p "$staging"
  if have unzip; then
    unzip -q "$archive" -d "$staging"
  else
    have python3 || die "unzip or python3 is required"
    python3 -m zipfile -e "$archive" "$staging"
  fi
  [[ -f "$staging/Docs/Sample.plist" ]] || die "OpenCore archive lacks Docs/Sample.plist"
  mkdir -p "$(dirname "$cache_root")"
  mv -- "$staging" "$cache_root"
}

validate_cache() {
  local root="$1" version="$2" variant="$3"
  [[ -f "$root/Docs/Sample.plist" ]] || die "OpenCore cache incomplete: $root"
  [[ -f "$root/IA32/EFI/OC/OpenCore.efi" ]] || die "OpenCore $version $variant has no IA32 OpenCore.efi"
  [[ -f "$root/IA32/EFI/BOOT/BOOTIA32.efi" ]] || die "OpenCore $version $variant has no BOOTIA32.efi"
  [[ -f "$root/Utilities/LegacyBoot/bootIA32" ]] || die "OpenCore $version $variant has no LegacyBoot/bootIA32"
  [[ -f "$root/Utilities/LegacyBoot/boot0" ]] || die "OpenCore $version $variant has no LegacyBoot/boot0"
  [[ -f "$root/Utilities/LegacyBoot/boot1f32" ]] || die "OpenCore $version $variant has no LegacyBoot/boot1f32"
}

select_cache() {
  local version="$1" variant="$2" cache_rel="opencore/$1/$2"
  local cache_root="$CACHE_DIR/$cache_rel"
  validate_cache "$cache_root" "$version" "$variant"
  [[ -f "$CURRENT_SOURCES" ]] \
    || die "Missing $CURRENT_SOURCES. Run the normal --download once so kext/HFS metadata exists."
  have python3 || die "python3 is required"
  python3 - "$CURRENT_SOURCES" "$version" "$variant" "$cache_rel" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1])
updates={
    'OC_VERSION': sys.argv[2],
    'OC_VARIANT': sys.argv[3],
    'OC_CACHE_REL': sys.argv[4],
}
lines=path.read_text(encoding='utf-8').splitlines()
out=[]
seen=set()
for line in lines:
    if '=' in line and not line.startswith('#'):
        key=line.split('=',1)[0]
        if key in updates:
            out.append(f'{key}={updates[key]}')
            seen.add(key)
            continue
    out.append(line)
for key in ('OC_VERSION','OC_VARIANT','OC_CACHE_REL'):
    if key not in seen:
        out.append(f'{key}={updates[key]}')
path.write_text('\n'.join(out)+'\n', encoding='utf-8')
PY
  log "Selected OpenCore $version $variant ($cache_rel)"
}

if [[ "$MODE" == download ]]; then
  release_output="$(resolve_release "$VERSION" "$VARIANT")" \
    || die "Could not parse OpenCore release metadata"
  resolved_version="$(printf '%s\n' "$release_output" | sed -n '1p')"
  url="$(printf '%s\n' "$release_output" | sed -n '2p')"
  [[ -n "$resolved_version" && -n "$url" ]] || die "OpenCore release metadata is incomplete"
  archive="$DOWNLOADS_DIR/OpenCore-${resolved_version}-${VARIANT}.zip"
  cache_root="$CACHE_DIR/opencore/$resolved_version/$VARIANT"
  mkdir -p "$DOWNLOADS_DIR"
  if [[ ! -s "$archive" ]]; then
    log "Downloading OpenCore $resolved_version $VARIANT"
    curl -fL --retry 3 --connect-timeout 20 -o "${archive}.part" "$url"
    [[ -s "${archive}.part" ]] || die "Empty download: $url"
    mv -- "${archive}.part" "$archive"
  else
    log "Using cached archive: $archive"
  fi
  digest="$(sha256_file "$archive")"
  record_manifest "$resolved_version-$VARIANT" "$url" "$(basename "$archive")" "$digest"
  extract_archive "$archive" "$cache_root"
  validate_cache "$cache_root" "$resolved_version" "$VARIANT"
  select_cache "$resolved_version" "$VARIANT"
else
  resolved_version="$VERSION"
  if [[ "$resolved_version" == latest ]]; then
    resolved_version="$(current_value OC_VERSION || true)"
    [[ -n "$resolved_version" ]] || die "Cannot resolve 'latest' without current-sources.env; use --download"
  fi
  select_cache "$resolved_version" "$VARIANT"
fi
