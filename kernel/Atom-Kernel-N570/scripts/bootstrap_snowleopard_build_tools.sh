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
# XNU 1504 expects kextsymboltool as a host-side Darwin build helper, but the
# xnu-1504.3.12 public source snapshot does not include its SETUP source.
# Pin the later Apple OSS copy to one exact XNU commit; its own Makefile builds
# this file as a host tool with libstdc++.
KEXTSYMBOLTOOL_COMMIT="855239e564a912940801207fb9053ef0c13fd3cc"
KEXTSYMBOLTOOL_URL="https://raw.githubusercontent.com/apple-oss-distributions/xnu/$KEXTSYMBOLTOOL_COMMIT/SETUP/kextsymboltool/kextsymboltool.c"
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
have curl || die "curl is required"

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

KEXTSYMBOLTOOL_SRC="$WORK_DIR/kextsymboltool-$KEXTSYMBOLTOOL_COMMIT.c"
if [ ! -s "$KEXTSYMBOLTOOL_SRC" ]; then
  log "fetching pinned Apple kextsymboltool source"
  rm -f "$KEXTSYMBOLTOOL_SRC.tmp"
  curl --fail --location --silent --show-error \
    "$KEXTSYMBOLTOOL_URL" \
    -o "$KEXTSYMBOLTOOL_SRC.tmp"
  [ -s "$KEXTSYMBOLTOOL_SRC.tmp" ] || die "downloaded kextsymboltool source is empty"
  mv "$KEXTSYMBOLTOOL_SRC.tmp" "$KEXTSYMBOLTOOL_SRC"
fi
log "building kextsymboltool from Apple XNU source"
"$CC" -arch i386 -Os -Wall -isysroot "$SDKROOT" \
  "$KEXTSYMBOLTOOL_SRC" \
  -o "$BIN_DIR/kextsymboltool" \
  -lstdc++

chmod 0755 \
  "$BIN_DIR/relpath" \
  "$BIN_DIR/decomment" \
  "$BIN_DIR/setsegname" \
  "$BIN_DIR/kextsymboltool"

# Lightweight execution checks. relpath requires existing paths; setsegname
# and kextsymboltool with no arguments must execute and return usage/errors
# instead of failing to launch.
"$BIN_DIR/relpath" "$ROOT_DIR" "$ROOT_DIR/src/xnu/Makefile" >/dev/null
"$BIN_DIR/decomment" "$SRC_DIR/decomment.tproj/decomment.c" >/dev/null
"$BIN_DIR/setsegname" >/dev/null 2>&1 && die "setsegname unexpectedly accepted empty arguments" || true
"$BIN_DIR/kextsymboltool" >/dev/null 2>&1 && die "kextsymboltool unexpectedly accepted empty arguments" || true

for tool in relpath decomment setsegname kextsymboltool; do
  [ -x "$BIN_DIR/$tool" ] || die "$tool was not built"
  file "$BIN_DIR/$tool" | grep -q 'Mach-O' || die "$tool is not a Mach-O executable: $BIN_DIR/$tool"
done

log "relpath: $BIN_DIR/relpath"
log "decomment: $BIN_DIR/decomment"
log "setsegname: $BIN_DIR/setsegname"
log "kextsymboltool: $BIN_DIR/kextsymboltool"
log "bootstrap tools: PASS"
