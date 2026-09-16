#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
WORK_DIR="$ROOT_DIR/work/build-tools"
SRC_DIR="$WORK_DIR/bootstrap_cmds-72"
BIN_DIR="$WORK_DIR/bin"
VENDORED_DIR="$ROOT_DIR/tools/snowleopard"
SDKROOT="${SDKROOT:-/Developer/SDKs/MacOSX10.6.sdk}"

BOOTSTRAP_REPO="https://github.com/apple-oss-distributions/bootstrap_cmds.git"
BOOTSTRAP_COMMIT="46504af5bfee6086d69d889c07bd5ca865b29fd1"
CC="${CC_BOOTSTRAP:-/Developer/usr/bin/gcc-4.2}"

log() { printf '[atom-kernel-tools] %s\n' "$*"; }
die() { printf '[atom-kernel-tools] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname -s)" = Darwin ] || die "this helper is intended for the Snow Leopard build host"
case "$(sw_vers -productVersion 2>/dev/null || true)" in
  10.6*) ;;
  *) die "expected Mac OS X 10.6.x" ;;
esac

[ -x "$CC" ] || die "gcc-4.2 not found: $CC"
[ -d "$SDKROOT" ] || die "Snow Leopard SDK not found: $SDKROOT"
have git || die "git is required"

mkdir -p "$WORK_DIR" "$BIN_DIR"

if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  log "cloning Apple bootstrap_cmds"
  git clone "$BOOTSTRAP_REPO" "$SRC_DIR"
fi

cd "$SRC_DIR"
git fetch origin >/dev/null 2>&1 || true
git checkout -f "$BOOTSTRAP_COMMIT"

CURRENT="$(git rev-parse HEAD)"
[ "$CURRENT" = "$BOOTSTRAP_COMMIT" ] || die "bootstrap_cmds checkout mismatch: $CURRENT"

log "building relpath from bootstrap_cmds-72"
"$CC" -arch i386 -Os -Wall \
  "$SRC_DIR/relpath.tproj/relpath.c" \
  -o "$BIN_DIR/relpath"

log "building decomment from bootstrap_cmds-72"
"$CC" -arch i386 -Os -Wall \
  "$SRC_DIR/decomment.tproj/decomment.c" \
  -o "$BIN_DIR/decomment"

SETSEGNAME_SRC="$VENDORED_DIR/setsegname.c"
[ -f "$SETSEGNAME_SRC" ] || die "vendored setsegname source missing: $SETSEGNAME_SRC"
log "building setsegname from Apple XNU source"
"$CC" -arch i386 -Os -Wall -isysroot "$SDKROOT" \
  "$SETSEGNAME_SRC" \
  -o "$BIN_DIR/setsegname"

chmod 0755 "$BIN_DIR/relpath" "$BIN_DIR/decomment" "$BIN_DIR/setsegname"

# Lightweight execution checks. relpath requires existing paths; setsegname
# with no arguments must execute and return its usage error instead of failing
# to launch.
"$BIN_DIR/relpath" "$ROOT_DIR" "$ROOT_DIR/src/xnu/Makefile" >/dev/null
"$BIN_DIR/decomment" "$SRC_DIR/decomment.tproj/decomment.c" >/dev/null
"$BIN_DIR/setsegname" >/dev/null 2>&1 && die "setsegname unexpectedly accepted empty arguments" || true

for tool in relpath decomment setsegname; do
  [ -x "$BIN_DIR/$tool" ] || die "$tool was not built"
  file "$BIN_DIR/$tool" | grep -q 'Mach-O' || die "$tool is not a Mach-O executable: $BIN_DIR/$tool"
done

log "relpath: $BIN_DIR/relpath"
log "decomment: $BIN_DIR/decomment"
log "setsegname: $BIN_DIR/setsegname"
log "bootstrap tools: PASS"
