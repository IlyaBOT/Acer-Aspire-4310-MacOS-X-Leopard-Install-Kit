#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEST="${1:-$ROOT_DIR/input/kernels/snowleopard/asus-eee-pc-1215p-kernel}"
TMP=""

log() { printf '[atom-1063] %s\n' "$*"; }
die() { printf '[atom-1063] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf -- "$TMP" || true; }
trap cleanup EXIT INT TERM

for c in curl python3 file strings; do have "$c" || die "Missing required command: $c"; done
[[ "$(uname -s)" == Darwin ]] || die "Automatic PKG extraction currently requires macOS (pkgutil --expand-full)."
have pkgutil || die "pkgutil is required"

mkdir -p "$(dirname "$DEST")"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/atom1063.XXXXXX")"
ZIP="$TMP/kernel.zip"

# Historical provenance. The exact 10.6.3 package was published by nawcom/qoopz
# in April 2010; direct hosts are tried first and the Internet Archive is used
# only as a preservation fallback.
SOURCES=(
  "http://dl.nawcom.com/legacy_kernel-10.3.0.pkg.zip"
  "http://nawcom.com/osx86/files/10.6/Kernels/10.3.0/legacy_kernel-10.3.0.pkg.zip"
  "http://olarila.com/files/10.6/Kernels/10.3.0/legacy_kernel-10.3.0.pkg.zip"
)

USED_URL=""
for url in "${SOURCES[@]}"; do
  log "Trying historical source: $url"
  if curl -fL --retry 2 --connect-timeout 12 --max-time 90 -o "$ZIP.part" "$url" 2>/dev/null && [[ -s "$ZIP.part" ]]; then
    mv "$ZIP.part" "$ZIP"
    USED_URL="$url"
    break
  fi
  rm -f "$ZIP.part"
done

if [[ -z "$USED_URL" ]]; then
  log "Original hosts unavailable; querying Internet Archive CDX"
  for original in "${SOURCES[@]}"; do
    cdx="$TMP/cdx.json"
    encoded="$(python3 - "$original" <<'PY'
import sys,urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
)"
    if ! curl -fsSL --retry 2 \
      "https://web.archive.org/cdx/search/cdx?url=$encoded&output=json&filter=statuscode:200&fl=timestamp,original&collapse=digest&limit=20" \
      -o "$cdx"; then
      continue
    fi
    snapshot="$(python3 - "$cdx" <<'PY'
import json,sys
try: data=json.load(open(sys.argv[1], encoding='utf-8'))
except Exception: raise SystemExit
rows=data[1:] if isinstance(data,list) and data else []
if rows:
    ts,url=rows[-1][0],rows[-1][1]
    print(f'https://web.archive.org/web/{ts}id_/{url}')
PY
)"
    [[ -n "$snapshot" ]] || continue
    log "Trying archived source: $snapshot"
    if curl -fL --retry 3 --connect-timeout 20 --max-time 180 -o "$ZIP.part" "$snapshot" && [[ -s "$ZIP.part" ]]; then
      mv "$ZIP.part" "$ZIP"
      USED_URL="$snapshot"
      break
    fi
    rm -f "$ZIP.part"
  done
fi

[[ -s "$ZIP" ]] || die "Could not retrieve the historical 10.6.3 kernel package. Download a known-good Atom/legacy Darwin 10.3.0 i386 kernel manually and save it as: $DEST"

python3 -m zipfile -e "$ZIP" "$TMP/unzip" || die "Downloaded file is not a valid ZIP"
PKG="$(find "$TMP/unzip" -type d -name '*.pkg' -print -quit)"
[[ -n "$PKG" ]] || PKG="$(find "$TMP/unzip" -type f -name '*.pkg' -print -quit)"
[[ -n "$PKG" ]] || die "ZIP contains no .pkg"

mkdir -p "$TMP/expanded"
pkgutil --expand-full "$PKG" "$TMP/expanded" >/dev/null || die "pkgutil could not expand the package"
KERNEL="$(find "$TMP/expanded" -type f \( -name 'legacy_kernel' -o -name 'mach_kernel' -o -name 'mach_kernel_atom' -o -name 'mach_atom' \) -print -quit)"
[[ -n "$KERNEL" ]] || die "Expanded package contains no recognizable kernel binary"

file "$KERNEL" | grep -Eqi 'Mach-O.*i386|Mach-O universal.*i386' \
  || die "Kernel is not an i386 Mach-O: $(file "$KERNEL")"
if ! strings "$KERNEL" | grep -Eq 'Darwin Kernel Version 10\.3\.0|xnu-1504\.3\.12'; then
  die "Kernel does not identify itself as Darwin 10.3.0 / xnu-1504.3.12"
fi

cp -p "$KERNEL" "$DEST"
chmod 0644 "$DEST"
if command -v shasum >/dev/null 2>&1; then
  SHA="$(shasum -a 256 "$DEST" | awk '{print $1}')"
else
  SHA="$(openssl dgst -sha256 "$DEST" | awk '{print $NF}')"
fi
cat >"$DEST.source.txt" <<EOF
source=$USED_URL
sha256=$SHA
expected=Darwin 10.3.0 / xnu-1504.3.12 / i386
note=Historical third-party kernel; hash records the retrieved artifact and is not an authoritative upstream reference hash.
EOF

log "Verified kernel: $DEST"
log "SHA-256: $SHA"
