#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
OUT_ROOT="$ROOT_DIR/downloads/amd-kernels"
CACHE_ENV="$ROOT_DIR/cache/amd-kernels.env"
INSPECTOR="$SCRIPT_DIR/inspect_artifact.py"

# User-maintained mirror containing several historical Snow Leopard kernels.
# The downloader treats this as the primary source, enumerates the directory
# index when possible, and still validates the extracted Mach-O before use.
MIRROR_BASE_URL="https://ibifs.ddns.net/%D0%9F%D1%80%D0%BE%D1%87%D0%B5%D0%B5/%D1%8F%D0%B1%D0%BB%D0%BE%D1%87%D0%BA%D0%B8/Legacy%20Kernal%20hackintosh/"

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

Primary source:
  https://ibifs.ddns.net/.../Legacy Kernal hackintosh/

The mirror contains several historical kernel variants. The script enumerates the
HTTP directory listing when available, ranks filenames matching the requested
Snow Leopard/Darwin version, downloads ZIP candidates, and accepts a kernel only
when it is an i386 Mach-O advertising the expected Darwin or XNU version.

Known historical nawcom URLs and Internet Archive captures remain as emergency
fallbacks when the mirror is unavailable.

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

# Enumerate ZIP files from the user's mirror and rank likely matches first.
# This deliberately does not trust filenames: final acceptance is based on the
# extracted Mach-O architecture and Darwin/XNU strings.
server_catalog_urls() {
  local osver="$1" darwin="$2" index_file
  index_file="$(mktemp /tmp/amd-kernel-index.XXXXXX)"
  if ! curl -fsSL --retry 2 --connect-timeout 20 --max-time 60 \
      -o "$index_file" "$MIRROR_BASE_URL" 2>/dev/null; then
    rm -f "$index_file"
    warn "Could not enumerate primary mirror directory: $MIRROR_BASE_URL"
    return 0
  fi

  python3 - "$MIRROR_BASE_URL" "$osver" "$darwin" "$index_file" <<'PY'
from html.parser import HTMLParser
from pathlib import PurePosixPath
from urllib.parse import urljoin, urlsplit, unquote, quote, urlunsplit
import sys

base, osver, darwin, path = sys.argv[1:]

class P(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs=[]
    def handle_starttag(self, tag, attrs):
        if tag.lower() != 'a':
            return
        for k,v in attrs:
            if k.lower() == 'href' and v:
                self.hrefs.append(v)

p=P()
with open(path, 'r', encoding='utf-8', errors='ignore') as f:
    p.feed(f.read())

want_tokens = {osver.lower(), darwin.lower()}
rows=[]
seen=set()
for href in p.hrefs:
    full=urljoin(base, href)
    parts=urlsplit(full)
    name=unquote(PurePosixPath(parts.path).name)
    low=name.lower()
    if not low.endswith('.zip'):
        continue
    if not any(tok in low for tok in want_tokens):
        continue
    if not any(k in low for k in ('kernel', 'kernal', 'nawcom', 'anv', 'qoopz')):
        continue

    # Re-encode non-ASCII/spaces while preserving URL separators and percent escapes.
    enc_path=quote(unquote(parts.path), safe="/%:@-._~!$&'()*+,;=")
    full=urlunsplit((parts.scheme, parts.netloc, enc_path, parts.query, parts.fragment))
    if full in seen:
        continue
    seen.add(full)

    score=0
    if darwin in low: score += 100
    if osver in low: score += 80
    if 'legacy_kernel' in low: score += 60
    if '.pkg.zip' in low: score += 40
    if 'nawcom' in low or 'qoopz' in low: score += 20
    if osver == '10.6.8' and 'v2' in low: score += 100
    if 'sinetek' in low: score -= 30  # x86_64 experiments are not first choice here
    rows.append((score, name, full))

for _,_,url in sorted(rows, key=lambda x:(-x[0], x[1].lower())):
    print(url)
PY
  rm -f "$index_file"
}

valid_zip() {
  local path="$1"
  [[ -s "$path" ]] || return 1
  python3 - "$path" <<'PY'
import sys,zipfile
raise SystemExit(0 if zipfile.is_zipfile(sys.argv[1]) else 1)
PY
}

download_one_zip() {
  local destination="$1" url="$2" tmp archive_url
  tmp="${destination}.part"
  rm -f "$tmp"

  log "Trying $url"
  if curl -fL --retry 2 --connect-timeout 20 --max-time 600 -o "$tmp" "$url" 2>/dev/null && valid_zip "$tmp"; then
    mv -f "$tmp" "$destination"
    printf '%s\n' "$url" > "${destination}.source-url"
    return 0
  fi
  rm -f "$tmp"

  # Do not ask Wayback to archive/resolve files on the user's live mirror.
  if [[ "$url" == "$MIRROR_BASE_URL"* ]]; then
    return 1
  fi

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
  done < <(find "$root" -type f \( -name legacy_kernel -o -name mach_kernel -o -name kernel -o -name '*kernel*' \) -print0 2>/dev/null)
  return 1
}

kernel_matches() {
  local kernel="$1" darwin="$2" xnu="$3"
  python3 "$INSPECTOR" --binary "$kernel" --require-arch i386 --quiet >/dev/null 2>&1 \
    || return 1
  strings "$kernel" | grep -Fq "Darwin Kernel Version $darwin" && return 0
  strings "$kernel" | grep -Fq "xnu-$xnu" && return 0
  return 1
}

validate_kernel() {
  local kernel="$1" darwin="$2" xnu="$3"
  kernel_matches "$kernel" "$darwin" "$xnu" \
    || die "Kernel is not a verified i386 Darwin $darwin / xnu-$xnu Mach-O: $kernel"
}

extract_kernel_from_zip() {
  local archive="$1" darwin="$2" xnu="$3" work="$4"
  local pkg kernel
  mkdir -p "$work/unzip"
  unzip -q "$archive" -d "$work/unzip" || return 1

  # Some archives contain the raw legacy_kernel directly rather than a .pkg.
  kernel="$(find_kernel_candidate "$work/unzip" || true)"
  if [[ -n "$kernel" ]] && kernel_matches "$kernel" "$darwin" "$xnu"; then
    printf '%s\n' "$kernel"
    return 0
  fi

  while IFS= read -r -d '' pkg; do
    rm -rf "$work/pkg"
    if expand_pkg_tree "$pkg" "$work/pkg"; then
      kernel="$(find_kernel_candidate "$work/pkg" || true)"
      if [[ -n "$kernel" ]] && kernel_matches "$kernel" "$darwin" "$xnu"; then
        printf '%s\n' "$kernel"
        return 0
      fi
    fi
  done < <(find "$work/unzip" \( -type f -o -type d \) -name '*.pkg' -print0 2>/dev/null)

  return 1
}

install_kernel_release() {
  local osver="$1" darwin="$2" xnu="$3" archive_name="$4"; shift 4
  local dir="$OUT_ROOT/$osver" archive="$OUT_ROOT/$osver/$archive_name"
  local work kernel source_url url accepted=0
  mkdir -p "$dir"

  if [[ $FORCE -eq 0 && -s "$dir/legacy_kernel" ]]; then
    validate_kernel "$dir/legacy_kernel" "$darwin" "$xnu"
    log "Already present and valid: $dir/legacy_kernel"
    return 0
  fi

  rm -f "$dir/legacy_kernel" "$dir/SHA256SUMS.txt"

  for url in "$@"; do
    [[ -n "$url" ]] || continue
    rm -f "$archive" "${archive}.source-url"
    if ! download_one_zip "$archive" "$url"; then
      continue
    fi

    work="$(mktemp -d /tmp/amd-snow-kernel.XXXXXX)"
    kernel="$(extract_kernel_from_zip "$archive" "$darwin" "$xnu" "$work" || true)"
    if [[ -n "$kernel" ]]; then
      cp -f "$kernel" "$dir/legacy_kernel"
      chmod 0644 "$dir/legacy_kernel"
      accepted=1
      rm -rf -- "$work"
      break
    fi

    warn "Rejected candidate: $(cat "${archive}.source-url" 2>/dev/null || printf '%s' "$url") (no matching i386 Darwin $darwin / xnu-$xnu kernel)"
    rm -rf -- "$work"
  done

  [[ $accepted -eq 1 ]] \
    || die "Could not find a valid i386 Darwin $darwin / xnu-$xnu kernel for OS X $osver"

  source_url="$(cat "${archive}.source-url" 2>/dev/null || printf UNKNOWN)"
  {
    printf 'OS_X_VERSION=%s\n' "$osver"
    printf 'DARWIN_VERSION=%s\n' "$darwin"
    printf 'XNU_VERSION=%s\n' "$xnu"
    printf 'SOURCE_URL=%s\n' "$source_url"
    printf 'PRIMARY_MIRROR=%s\n' "$MIRROR_BASE_URL"
    printf 'NOTE=Historical third-party AMD kernel; locally verified for i386 and version strings, not authenticated by a project-maintained reference hash.\n'
  } > "$dir/SOURCE.txt"
  (
    cd "$dir"
    sha256sum "$archive_name" legacy_kernel > SHA256SUMS.txt
  )
  log "Prepared OS X $osver AMD kernel: $dir/legacy_kernel"
  log "Accepted source: $source_url"
}

prepare_1063() {
  local -a mirror=()
  mapfile -t mirror < <(server_catalog_urls "10.6.3" "10.3.0")
  install_kernel_release \
    "10.6.3" "10.3.0" "1504.3.12" "legacy_kernel-10.3.0.pkg.zip" \
    "${mirror[@]}" \
    "${MIRROR_BASE_URL}legacy_kernel-10.3.0.pkg.zip" \
    "${MIRROR_BASE_URL}legacy_kernel-10.3.0.%2810.6.3%29.pkg.zip" \
    "${MIRROR_BASE_URL}legacy_kernel.10.3.0.%2810.6.3%29.zip" \
    "http://nawcom.com/osx86/files/10.6/Kernels/10.3.0/legacy_kernel-10.3.0.pkg.zip" \
    "http://dl.nawcom.com/Kernels/10.3.0/legacy_kernel-10.3.0.pkg.zip"
}

prepare_1068() {
  local -a mirror=()
  mapfile -t mirror < <(server_catalog_urls "10.6.8" "10.8.0")
  install_kernel_release \
    "10.6.8" "10.8.0" "1504.15.3" "legacy_kernel-10.6.8.v2.pkg.zip" \
    "${mirror[@]}" \
    "${MIRROR_BASE_URL}legacy_kernel-10.6.8.v2.pkg.zip" \
    "${MIRROR_BASE_URL}legacy_kernel-10.8.0.%2810.6.8%29.pkg.zip" \
    "${MIRROR_BASE_URL}legacy_kernel.10.8.0.%2810.6.8%29.zip" \
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
