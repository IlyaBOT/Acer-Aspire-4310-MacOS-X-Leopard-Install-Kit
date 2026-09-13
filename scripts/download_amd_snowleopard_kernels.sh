#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
OUT_ROOT="$ROOT_DIR/downloads/amd-kernels"
CACHE_ENV="$ROOT_DIR/cache/amd-kernels.env"
INSPECTOR="$SCRIPT_DIR/inspect_artifact.py"

MODE="all"
FORCE=0

usage() {
  cat <<'USAGE'
Download and extract historical AMD Snow Leopard legacy kernels.

Usage:
  ./scripts/download_amd_snowleopard_kernels.sh [--all|--1063|--1068] [--force]

Outputs:
  downloads/amd-kernels/10.6.3/legacy_kernel
  downloads/amd-kernels/10.6.8/legacy_kernel
  cache/amd-kernels.env

Sources are historical nawcom/qoopz release URLs. Because the original hosts are
old and may be offline, the downloader tries the original URL first and then asks
the Internet Archive CDX API for an archived copy of the same URL.

The project does not ship these kernels. Every downloaded archive and extracted
kernel gets a local SHA-256 manifest. There are no project-maintained trusted
reference hashes for these historical binaries, so version and architecture are
also verified from the Mach-O/string metadata before use.
USAGE
}

log() { printf '[amd-kernel] %s\n' "$*"; }
warn() { printf '[amd-kernel] WARNING: %s\n' "$*" >&2; }
die() { printf '[amd-kernel] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

while (($#)); do
  case "$1" in
    --all) MODE=all ;;
    --1063) MODE=1063 ;;
    --1068) MODE=1068 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

for cmd in curl python3 unzip file strings sha256sum find awk sed grep; do
  have "$cmd" || die "Missing required command: $cmd"
done
[[ -f "$INSPECTOR" ]] || die "Missing inspector: $INSPECTOR"

mkdir -p "$OUT_ROOT" "$(dirname "$CACHE_ENV")"

wayback_capture_url() {
  local original="$1" response
  response="$(curl -fsSLG --retry 2 --connect-timeout 15 \
    'https://web.archive.org/cdx/search/cdx' \
    --data-urlencode "url=$original" \
    --data-urlencode 'output=json' \
    --data-urlencode 'fl=timestamp,original,statuscode,mimetype' \
    --data-urlencode 'filter=statuscode:200' \
    --data-urlencode 'filter=mimetype:application/zip' \
    --data-urlencode 'filter=collapse:digest' \
    --data-urlencode 'limit=-1' 2>/dev/null || true)"
  [[ -n "$response" ]] || return 1
  python3 - "$response" <<'PY'
import json,sys
try:
    rows=json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if not isinstance(rows,list) or len(rows) < 2:
    raise SystemExit(1)
row=rows[-1]
if len(row) < 2:
    raise SystemExit(1)
print(f"https://web.archive.org/web/{row[0]}id_/{row[1]}")
PY
}

valid_zip() {
  local path="$1"
  [[ -s "$path" ]] || return 1
  python3 - "$path" <<'PY'
import sys,zipfile
raise SystemExit(0 if zipfile.is_zipfile(sys.argv[1]) else 1)
PY
}

download_archive() {
  local destination="$1"; shift
  local url archive_url tmp
  tmp="${destination}.part"
  rm -f "$tmp"
  for url in "$@"; do
    log "Trying $url"
    if curl -fL --retry 2 --connect-timeout 20 --max-time 300 -o "$tmp" "$url" 2>/dev/null && valid_zip "$tmp"; then
      mv -f "$tmp" "$destination"
      printf '%s\n' "$url" > "${destination}.source-url"
      return 0
    fi
    rm -f "$tmp"
    archive_url="$(wayback_capture_url "$url" || true)"
    if [[ -n "$archive_url" ]]; then
      log "Trying archived capture: $archive_url"
      if curl -fL --retry 2 --connect-timeout 20 --max-time 600 -o "$tmp" "$archive_url" 2>/dev/null && valid_zip "$tmp"; then
        mv -f "$tmp" "$destination"
        printf '%s\n' "$archive_url" > "${destination}.source-url"
        return 0
      fi
      rm -f "$tmp"
    fi
  done
  return 1
}

extract_payload() {
  local payload="$1" out="$2"
  mkdir -p "$out"
  if have bsdtar && bsdtar -xf "$payload" -C "$out" >/dev/null 2>&1; then
    return 0
  fi
  if have cpio; then
    if gzip -dc "$payload" 2>/dev/null | (cd "$out" && cpio -idm --quiet) 2>/dev/null; then return 0; fi
    if bzip2 -dc "$payload" 2>/dev/null | (cd "$out" && cpio -idm --quiet) 2>/dev/null; then return 0; fi
    if xz -dc "$payload" 2>/dev/null | (cd "$out" && cpio -idm --quiet) 2>/dev/null; then return 0; fi
  fi
  return 1
}

expand_pkg_tree() {
  local pkg="$1" out="$2" depth="${3:-0}" child payload idx=0
  (( depth <= 4 )) || return 0
  mkdir -p "$out"

  if [[ -d "$pkg" ]]; then
    cp -a "$pkg"/. "$out"/
  elif have xar && xar -tf "$pkg" >/dev/null 2>&1; then
    (cd "$out" && xar -xf "$pkg")
  elif have bsdtar && bsdtar -tf "$pkg" >/dev/null 2>&1; then
    bsdtar -xf "$pkg" -C "$out"
  else
    return 1
  fi

  while IFS= read -r -d '' payload; do
    idx=$((idx+1))
    extract_payload "$payload" "$out/payload-$idx" || true
  done < <(find "$out" -type f \( -name Payload -o -name 'Archive.pax.gz' -o -name 'Archive.pax' \) -print0 2>/dev/null)

  while IFS= read -r -d '' child; do
    [[ "$child" != "$pkg" ]] || continue
    expand_pkg_tree "$child" "$out/nested-$depth-$(basename "$child")" $((depth+1)) || true
  done < <(find "$out" -mindepth 1 \( -type f -o -type d \) -name '*.pkg' -print0 2>/dev/null)
}

find_kernel_candidate() {
  local root="$1" candidate
  while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -qi 'Mach-O'; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$root" -type f \( -name legacy_kernel -o -name mach_kernel -o -name kernel \) -print0 2>/dev/null)
  return 1
}

validate_kernel() {
  local kernel="$1" darwin="$2" xnu="$3"
  python3 "$INSPECTOR" --binary "$kernel" --require-arch i386 --quiet \
    || die "Kernel is not a verified i386 Mach-O: $kernel"
  if ! strings "$kernel" | grep -Fq "Darwin Kernel Version $darwin"; then
    if ! strings "$kernel" | grep -Fq "xnu-$xnu"; then
      die "Kernel does not advertise Darwin $darwin or xnu-$xnu: $kernel"
    fi
  fi
}

install_kernel_release() {
  local osver="$1" darwin="$2" xnu="$3" archive_name="$4"; shift 4
  local dir="$OUT_ROOT/$osver" archive="$OUT_ROOT/$osver/$archive_name"
  local work pkg kernel source_url
  mkdir -p "$dir"

  if [[ $FORCE -eq 0 && -s "$dir/legacy_kernel" ]]; then
    validate_kernel "$dir/legacy_kernel" "$darwin" "$xnu"
    log "Already present and valid: $dir/legacy_kernel"
    return 0
  fi

  rm -f "$dir/legacy_kernel" "$dir/SHA256SUMS.txt"
  if [[ $FORCE -eq 1 || ! -s "$archive" ]]; then
    rm -f "$archive" "${archive}.source-url"
    download_archive "$archive" "$@" \
      || die "Could not download $archive_name from the historical source or its Internet Archive captures"
  fi
  valid_zip "$archive" || die "Downloaded file is not a ZIP archive: $archive"

  work="$(mktemp -d /tmp/amd-snow-kernel.XXXXXX)"
  trap 'rm -rf -- "$work"' RETURN
  unzip -q "$archive" -d "$work/unzip"

  pkg="$(find "$work/unzip" \( -type f -o -type d \) -name '*.pkg' -print -quit 2>/dev/null || true)"
  [[ -n "$pkg" ]] || die "No .pkg found inside $archive"
  expand_pkg_tree "$pkg" "$work/pkg" || die "Could not expand package $pkg; install libarchive-tools (bsdtar) or xar"
  kernel="$(find_kernel_candidate "$work/pkg" || true)"
  [[ -n "$kernel" ]] || die "Could not locate legacy_kernel inside $archive; install libarchive-tools/xar/cpio and retry"
  validate_kernel "$kernel" "$darwin" "$xnu"

  cp -f "$kernel" "$dir/legacy_kernel"
  chmod 0644 "$dir/legacy_kernel"
  source_url="$(cat "${archive}.source-url" 2>/dev/null || printf UNKNOWN)"
  {
    printf 'OS_X_VERSION=%s\n' "$osver"
    printf 'DARWIN_VERSION=%s\n' "$darwin"
    printf 'XNU_VERSION=%s\n' "$xnu"
    printf 'SOURCE_URL=%s\n' "$source_url"
    printf 'NOTE=Historical third-party AMD kernel; locally verified for i386 and version strings, not authenticated by a project-maintained reference hash.\n'
  } > "$dir/SOURCE.txt"
  (
    cd "$dir"
    sha256sum "$archive_name" legacy_kernel > SHA256SUMS.txt
  )
  rm -rf -- "$work"
  trap - RETURN
  log "Prepared OS X $osver AMD kernel: $dir/legacy_kernel"
}

prepare_1063() {
  install_kernel_release \
    "10.6.3" "10.3.0" "1504.3.12" "legacy_kernel-10.3.0.pkg.zip" \
    "http://nawcom.com/osx86/files/10.6/Kernels/10.3.0/legacy_kernel-10.3.0.pkg.zip" \
    "http://dl.nawcom.com/Kernels/10.3.0/legacy_kernel-10.3.0.pkg.zip"
}

prepare_1068() {
  install_kernel_release \
    "10.6.8" "10.8.0" "1504.15.3" "legacy_kernel-10.6.8.v2.pkg.zip" \
    "http://blog.nawcom.com/legacy_kernel-10.6.8.v2.pkg.zip" \
    "http://nawcom.com/osx86/files/10.6/Kernels/10.8.0/legacy_kernel-10.6.8.v2.pkg.zip"
}

case "$MODE" in
  all) prepare_1063; prepare_1068 ;;
  1063) prepare_1063 ;;
  1068) prepare_1068 ;;
  *) die "Unexpected mode: $MODE" ;;
esac

cat > "$CACHE_ENV" <<EOF_ENV
AMD_KERNEL_1063="$OUT_ROOT/10.6.3/legacy_kernel"
AMD_KERNEL_1068="$OUT_ROOT/10.6.8/legacy_kernel"
AMD_KERNEL_1063_DARWIN="10.3.0"
AMD_KERNEL_1068_DARWIN="10.8.0"
EOF_ENV

log "Kernel cache manifest: $CACHE_ENV"
