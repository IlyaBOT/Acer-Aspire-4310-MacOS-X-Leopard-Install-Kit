#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
SOURCE_DIR="$ROOT_DIR/output/cardreader/VoodooSDHCI-O2Micro-7120"
REMOTE_HOST="${ACER_HOST:-192.168.1.113}"
REMOTE_USER="${ACER_USER:-ilyabot}"
REMOTE_PARENT="/Users/$REMOTE_USER/Projects"
REMOTE_DIR="$REMOTE_PARENT/VoodooSDHCI-O2Micro-7120"

log() { printf '[cardreader-push] %s\n' "$*"; }
die() { printf '[cardreader-push] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$SOURCE_DIR" ]] || die "prepared source missing; run scripts/cardreader/prepare_o2micro_source.sh first"
command -v ssh >/dev/null 2>&1 || die "ssh is required"
command -v scp >/dev/null 2>&1 || die "scp is required"

SSH_OPTS=(-oHostKeyAlgorithms=+ssh-rsa)
TARGET="$REMOTE_USER@$REMOTE_HOST"

log "resetting $TARGET:$REMOTE_DIR"
ssh "${SSH_OPTS[@]}" "$TARGET" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_PARENT'"

log "copying patched source"
scp -O -r "${SSH_OPTS[@]}" "$SOURCE_DIR" "$TARGET:$REMOTE_PARENT/"

log "copying Snow Leopard build/install helpers"
scp -O "${SSH_OPTS[@]}" \
  "$SCRIPT_DIR/bootstrap_snowleopard.sh" \
  "$SCRIPT_DIR/build_snowleopard.sh" \
  "$SCRIPT_DIR/install_opencore_snowleopard.sh" \
  "$TARGET:$REMOTE_DIR/"

log "source deployed"
printf '\nOn the Acer:\n'
printf '  cd %s\n' "$REMOTE_DIR"
printf '  chmod +x bootstrap_snowleopard.sh build_snowleopard.sh install_opencore_snowleopard.sh\n'
printf '  ./bootstrap_snowleopard.sh\n'
printf '  ./build_snowleopard.sh .\n'
