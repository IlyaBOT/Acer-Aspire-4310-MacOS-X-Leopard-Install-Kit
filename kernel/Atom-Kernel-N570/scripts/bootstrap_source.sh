#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOCK_FILE="$ROOT_DIR/SOURCE.lock"
SRC_DIR="$ROOT_DIR/src/xnu"

[ -f "$LOCK_FILE" ] || { echo "[atom-kernel] ERROR: missing $LOCK_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$LOCK_FILE"

have() { command -v "$1" >/dev/null 2>&1; }
log() { printf '[atom-kernel] %s\n' "$*"; }
die() { printf '[atom-kernel] ERROR: %s\n' "$*" >&2; exit 1; }

have git || die "git is required"

if [ -f "$SRC_DIR/.xnu-source-commit" ]; then
  current="$(cat "$SRC_DIR/.xnu-source-commit")"
  if [ "$current" = "$XNU_COMMIT" ]; then
    log "source already pinned at $XNU_VERSION ($XNU_COMMIT)"
    exit 0
  fi
  die "existing source marker is $current, expected $XNU_COMMIT; remove $SRC_DIR manually if replacement is intended"
fi

if [ -e "$SRC_DIR" ]; then
  die "$SRC_DIR already exists without a valid source marker; refusing to overwrite"
fi

mkdir -p "$ROOT_DIR/src"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/xnu1504.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT INT TERM

log "cloning $XNU_REPOSITORY"
git clone --no-checkout "$XNU_REPOSITORY" "$TMP/xnu"
cd "$TMP/xnu"

log "checking out exact source commit $XNU_COMMIT"
git checkout --detach "$XNU_COMMIT"
actual="$(git rev-parse HEAD)"
[ "$actual" = "$XNU_COMMIT" ] || die "resolved source commit $actual does not match lock $XNU_COMMIT"

printf '%s\n' "$XNU_COMMIT" > .xnu-source-commit
rm -rf .git
mv "$TMP/xnu" "$SRC_DIR"

log "prepared $SRC_DIR"
log "version: $XNU_VERSION / Darwin $DARWIN_VERSION / Mac OS X $MACOS_VERSION"
