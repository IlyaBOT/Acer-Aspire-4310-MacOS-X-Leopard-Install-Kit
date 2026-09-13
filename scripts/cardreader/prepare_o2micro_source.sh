#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
UPSTREAM_URL="https://github.com/coolstar/VoodooSDHCI.git"
UPSTREAM_COMMIT="be8dc240a3b979d629660daea0d59c108ea86311"
CACHE_DIR="$ROOT_DIR/cache/cardreader/VoodooSDHCI-upstream"
OUT_DIR="$ROOT_DIR/output/cardreader/VoodooSDHCI-O2Micro-7120"
PATCHER="$SCRIPT_DIR/apply_o2micro_7120_patch.py"
HARDENER="$SCRIPT_DIR/harden_o2micro_cardinit.py"

log() { printf '[cardreader-prepare] %s\n' "$*"; }
die() { printf '[cardreader-prepare] ERROR: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[[ -f "$PATCHER" ]] || die "missing patcher: $PATCHER"
[[ -f "$HARDENER" ]] || die "missing hardener: $HARDENER"

mkdir -p "$(dirname "$CACHE_DIR")" "$(dirname "$OUT_DIR")"

if [[ ! -d "$CACHE_DIR/.git" ]]; then
  [[ ! -e "$CACHE_DIR" ]] || die "refusing to replace non-git path: $CACHE_DIR"
  log "cloning coolstar/VoodooSDHCI"
  git clone "$UPSTREAM_URL" "$CACHE_DIR"
fi

if ! git -C "$CACHE_DIR" diff --quiet --ignore-submodules --; then
  die "upstream cache has local modifications: $CACHE_DIR"
fi

git -C "$CACHE_DIR" fetch --quiet origin
git -C "$CACHE_DIR" checkout --quiet --detach "$UPSTREAM_COMMIT"
ACTUAL="$(git -C "$CACHE_DIR" rev-parse HEAD)"
[[ "$ACTUAL" == "$UPSTREAM_COMMIT" ]] || die "expected $UPSTREAM_COMMIT, got $ACTUAL"

case "$OUT_DIR" in
  "$ROOT_DIR"/output/cardreader/*) ;;
  *) die "refusing to clean unexpected output path: $OUT_DIR" ;;
esac
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Copy the pinned tree without its Git metadata; our repo owns the patch recipe,
# upstream history remains in cache/cardreader/VoodooSDHCI-upstream.
(
  cd "$CACHE_DIR"
  tar --exclude=.git -cf - .
) | (
  cd "$OUT_DIR"
  tar -xf -
)

python3 "$PATCHER" "$OUT_DIR"
python3 "$HARDENER" "$OUT_DIR"
printf '%s\n' "$UPSTREAM_COMMIT" > "$OUT_DIR/.upstream-commit"

log "prepared source: $OUT_DIR"
log "upstream: coolstar/VoodooSDHCI@$UPSTREAM_COMMIT"
log "inspect changes with:"
log "  git --no-pager diff --no-index '$CACHE_DIR' '$OUT_DIR' || true"
