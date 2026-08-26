#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SOURCE_DIR="$ROOT_DIR/cache/xnu-toolchain-sources"
WORK_DIR="$ROOT_DIR/output/xnu-legacy-tools-work"
ACTION="prepare"

COMPONENTS=(
  "bootstrap_cmds|https://github.com/apple-oss-distributions/bootstrap_cmds.git|df26aea3728854ec94a438b2bff58306d457cfef"
  "Libstreams|https://github.com/apple-oss-distributions/Libstreams.git|2fc9581ce7dca3e157f5529af4ed25cfd513a4be"
  "cctools|https://github.com/apple-oss-distributions/cctools.git|18acda4142e5a43362d44d3a5a01665e8c7d80e1"
  "IOKitUser|https://github.com/apple-oss-distributions/IOKitUser.git|0b6712423a745bdab1ce83bb35ca500629f8314b"
  "kext_tools|https://github.com/apple-oss-distributions/kext_tools.git|fc58a4f7334f7c09552c7a080e1ea2eeb1299df3"
  "developer_cmds|https://github.com/apple-oss-distributions/developer_cmds.git|2a55f1bd0d1ca529e7bb6728a872de2ffa1d1a92"
)

usage() {
  cat <<'EOF'
Prepare or install the Apple-era host tools needed to build XNU 1228.5.20.

Usage:
  scripts/prepare_xnu_legacy_tools.sh --prepare-only
  scripts/prepare_xnu_legacy_tools.sh --verify-only
  scripts/prepare_xnu_legacy_tools.sh --install

Preparation downloads pinned Apple OSS trees and works on a modern host. Installation
must run inside an isolated Leopard/Snow Leopard VM with Xcode 3.x installed. It builds
from disposable copies and installs only the expected files under /usr/local plus
/usr/bin/unifdef when that tool is absent.
EOF
}

log() { printf '[xnu-tools] %s\n' "$*"; }
die() { printf '[xnu-tools] ERROR: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --prepare-only) ACTION="prepare" ;;
    --verify-only) ACTION="verify" ;;
    --install) ACTION="install" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

component_fields() {
  local specification="$1"
  COMPONENT_NAME="${specification%%|*}"
  specification="${specification#*|}"
  COMPONENT_URL="${specification%%|*}"
  COMPONENT_COMMIT="${specification##*|}"
}

verify_component() {
  local specification="$1"
  local path actual
  component_fields "$specification"
  path="$SOURCE_DIR/$COMPONENT_NAME"
  if [[ -d "$path/.git" ]] && command -v git >/dev/null 2>&1; then
    actual="$(git -C "$path" rev-parse HEAD)"
    [[ "$actual" == "$COMPONENT_COMMIT" ]] \
      || die "$COMPONENT_NAME is at $actual; expected $COMPONENT_COMMIT"
    git -C "$path" diff --quiet --ignore-submodules -- \
      || die "$COMPONENT_NAME source tree has local modifications"
  elif [[ -f "$path/.aspire4310-source-commit" ]]; then
    actual="$(sed -n '1p' "$path/.aspire4310-source-commit")"
    [[ "$actual" == "$COMPONENT_COMMIT" ]] \
      || die "$COMPONENT_NAME offline marker is $actual; expected $COMPONENT_COMMIT"
  else
    die "Missing verifiable pinned source tree: $path"
  fi
}

prepare_sources() {
  local specification path
  command -v git >/dev/null 2>&1 || die "git is required to prepare tool sources"
  mkdir -p "$SOURCE_DIR"
  for specification in "${COMPONENTS[@]}"; do
    component_fields "$specification"
    path="$SOURCE_DIR/$COMPONENT_NAME"
    if [[ ! -d "$path/.git" ]]; then
      [[ ! -e "$path" ]] || die "Refusing to replace non-git path: $path"
      log "Cloning Apple $COMPONENT_NAME"
      git clone --quiet "$COMPONENT_URL" "$path"
    fi
    if [[ "$(git -C "$path" rev-parse HEAD)" != "$COMPONENT_COMMIT" ]]; then
      git -C "$path" diff --quiet --ignore-submodules -- \
        || die "$COMPONENT_NAME source tree has local modifications"
      git -C "$path" checkout --quiet "$COMPONENT_COMMIT"
    fi
    verify_component "$specification"
    log "$COMPONENT_NAME pinned at ${COMPONENT_COMMIT:0:12}"
  done
}

verify_sources() {
  local specification
  for specification in "${COMPONENTS[@]}"; do
    component_fields "$specification"
    verify_component "$specification"
    log "$COMPONENT_NAME verified at ${COMPONENT_COMMIT:0:12}"
  done
}

copy_sources_to_workdir() {
  local specification
  case "$WORK_DIR" in
    "$ROOT_DIR"/output/xnu-legacy-tools-work) ;;
    *) die "Refusing to clean unexpected work directory: $WORK_DIR" ;;
  esac
  rm -rf -- "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  for specification in "${COMPONENTS[@]}"; do
    component_fields "$specification"
    verify_component "$specification"
    cp -R "$SOURCE_DIR/$COMPONENT_NAME" "$WORK_DIR/$COMPONENT_NAME"
  done
}

build_pb_tool() {
  local directory="$1"
  (cd "$directory" && make all)
  (cd "$directory" && sudo make install)
}

install_tools() {
  [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] \
    || die "Tool installation must run inside the legacy Darwin build VM"
  [[ -d /Developer/Makefiles ]] || die "Xcode 3.x is not installed under /Developer"
  command -v make >/dev/null 2>&1 || die "make is missing"
  command -v gcc >/dev/null 2>&1 || die "Xcode GCC is missing"
  export MAKEFILEPATH="${MAKEFILEPATH:-/Developer/Makefiles}"

  copy_sources_to_workdir
  sudo mkdir -p /usr/local/bin /usr/local/lib /usr/local/include/mach-o \
    /usr/local/include/IOKit/kext

  log "Building relpath and decomment"
  build_pb_tool "$WORK_DIR/bootstrap_cmds/relpath.tproj"
  build_pb_tool "$WORK_DIR/bootstrap_cmds/decomment.tproj"

  log "Building Libstreams"
  (cd "$WORK_DIR/Libstreams" && make all && sudo make install)

  log "Building seg_hack and libkld"
  (
    cd "$WORK_DIR/cctools/libstuff"
    mv Makefile Makefile.apple
    sed 's,-DKERNEL,-I/usr/include -DKERNEL,g' Makefile.apple > Makefile
    make all
  )
  (cd "$WORK_DIR/cctools/misc" && make macos_all)
  sudo install -m 755 "$WORK_DIR/cctools/misc/seg_hack.NEW" /usr/local/bin/seg_hack
  (cd "$WORK_DIR/cctools/libmacho" && make macos)
  (
    cd "$WORK_DIR/cctools/ld"
    mv Makefile Makefile.apple
    sed 's,-DKERNEL,-I/usr/include -DKERNEL,g' Makefile.apple > Makefile
    make kld_build
  )
  sudo install -m 644 "$WORK_DIR/cctools/ld/static_kld/libkld.a" /usr/local/lib/libkld.a
  sudo install -m 644 "$WORK_DIR/cctools/include/mach-o/kld.h" /usr/local/include/mach-o/kld.h

  log "Installing IOKit kext headers and kextsymboltool"
  sudo install -m 644 \
    "$WORK_DIR/IOKitUser/kext.subproj/KXKext.h" \
    "$WORK_DIR/IOKitUser/kext.subproj/KXKextManager.h" \
    "$WORK_DIR/IOKitUser/kext.subproj/KXKextRepository.h" \
    /usr/local/include/IOKit/kext/
  gcc -I/usr/local/include "$WORK_DIR/kext_tools/kextsymboltool.c" \
    -o "$WORK_DIR/kextsymboltool"
  sudo install -m 755 "$WORK_DIR/kextsymboltool" /usr/local/bin/kextsymboltool

  if [[ ! -x /usr/bin/unifdef ]]; then
    log "Building unifdef"
    gcc "$WORK_DIR/developer_cmds/unifdef/unifdef.c" -o "$WORK_DIR/unifdef"
    sudo install -m 755 "$WORK_DIR/unifdef" /usr/bin/unifdef
  fi

  local required
  for required in \
    /usr/local/bin/decomment \
    /usr/local/bin/relpath \
    /usr/local/bin/seg_hack \
    /usr/local/bin/kextsymboltool \
    /usr/local/lib/libkld.a \
    /usr/bin/unifdef; do
    [[ -e "$required" ]] || die "Installation did not produce $required"
  done
  log "Legacy XNU host tools installed"
}

case "$ACTION" in
  prepare) prepare_sources ;;
  verify) verify_sources ;;
  install) install_tools ;;
esac
