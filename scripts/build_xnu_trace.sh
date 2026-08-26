#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PATCH_FILE="$ROOT_DIR/patches/xnu-1228.5.20-startup-trace.patch"
SOURCE_PARENT="$ROOT_DIR/cache/xnu-trace"
SOURCE_DIR="$SOURCE_PARENT/xnu-1228.5.20"
KERNEL_INPUT="$ROOT_DIR/input/kernels/leopard/kernel"
DIAGNOSTIC_OUTPUT="$ROOT_DIR/output/xnu-trace"

XNU_REPOSITORY="https://github.com/apple-oss-distributions/xnu.git"
XNU_TAG="xnu-1228.5.20"
XNU_COMMIT="f3fe36d86c12b679329ee4b45af0fc971368bf18"
ACTION="build"
JOBS="${XNU_JOBS:-2}"

usage() {
  cat <<'EOF'
Build the Aspire 4310 trace-release kernel from Apple's exact Leopard 10.5.4 XNU.

Usage:
  scripts/build_xnu_trace.sh --prepare-only
  scripts/build_xnu_trace.sh [--jobs N]

Environment overrides for a compatible legacy Darwin toolchain:
  XNU_CC=/usr/bin/gcc-4.0
  XNU_CXX=/usr/bin/g++-4.0

--prepare-only is host-independent: it downloads the pinned source and applies the
project patch. Compilation requires Darwin with an i386-capable Xcode-era compiler,
MIG, csh, seg_hack, relpath, libkld, and kextsymboltool.
EOF
}

log() { printf '[xnu-trace] %s\n' "$*"; }
die() { printf '[xnu-trace] ERROR: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --prepare-only) ACTION="prepare" ;;
    --jobs)
      (($# > 1)) || die "--jobs requires a positive integer"
      shift
      JOBS="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
[[ -f "$PATCH_FILE" ]] || die "Missing trace patch: $PATCH_FILE"
command -v git >/dev/null 2>&1 || die "git is required"

prepare_source() {
  mkdir -p "$SOURCE_PARENT"
  if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    [[ ! -e "$SOURCE_DIR" ]] || die "Refusing to replace non-git path: $SOURCE_DIR"
    log "Cloning Apple $XNU_TAG"
    git clone --quiet --depth 1 --branch "$XNU_TAG" "$XNU_REPOSITORY" "$SOURCE_DIR"
  fi

  local actual_commit
  actual_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
  [[ "$actual_commit" == "$XNU_COMMIT" ]] \
    || die "Unexpected XNU commit $actual_commit; expected $XNU_COMMIT"

  if git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    log "Startup trace patch is already applied"
  elif git -C "$SOURCE_DIR" apply --check "$PATCH_FILE"; then
    git -C "$SOURCE_DIR" apply "$PATCH_FILE"
    log "Applied startup trace patch"
  else
    die "XNU tree is modified in a way that does not match the project trace patch"
  fi

  grep -q '\[XNU-TRACE IO23\]' "$SOURCE_DIR/iokit/Kernel/IOStartIOKit.cpp" \
    || die "Patched source validation failed"
  log "Pinned source ready: $SOURCE_DIR"
}

require_legacy_toolchain() {
  [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] \
    || die "Compilation requires a legacy Darwin/Xcode environment; source preparation works on this host"

  local required
  local -a missing=()
  for required in \
    /bin/csh \
    /usr/bin/mig \
    /usr/bin/lipo \
    /usr/bin/strip \
    /usr/bin/unifdef \
    /usr/bin/gnutar \
    /usr/local/bin/decomment \
    /usr/local/bin/relpath \
    /usr/local/bin/seg_hack \
    /usr/local/bin/kextsymboltool \
    /usr/local/lib/libkld.a; do
    [[ -e "$required" ]] || missing+=("$required")
  done
  if ((${#missing[@]})); then
    printf '[xnu-trace] Missing Leopard XNU build prerequisites:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    die "Install the matching Apple 10.5.4/Xcode-era build tools in an isolated legacy Darwin environment"
  fi
}

check_i386_compiler() {
  local compiler="$1"
  local language="$2"
  local probe_dir probe
  [[ -x "$compiler" ]] || die "Compiler is not executable: $compiler"
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/aspire4310-xnu-cc.XXXXXX")"
  probe="$probe_dir/probe.o"
  if ! printf 'int aspire4310_xnu_probe;\n' \
    | "$compiler" -arch i386 -x "$language" -c -o "$probe" - >/dev/null 2>&1; then
    rm -rf -- "$probe_dir"
    die "$compiler cannot emit i386 Mach-O; use the Xcode 3.x GCC toolchain"
  fi
  /usr/bin/file "$probe" | grep -Eq 'Mach-O.*i386|Mach-O.*80386' \
    || { rm -rf -- "$probe_dir"; die "$compiler produced a non-i386 object"; }
  rm -rf -- "$probe_dir"
}

select_compiler() {
  local override="$1"
  shift
  local candidate
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return
  fi
  for candidate in "$@"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

build_kernel() {
  require_legacy_toolchain

  local cc cxx
  local built_kernel built_symbols
  cc="$(select_compiler "${XNU_CC:-}" /usr/bin/gcc-4.0 /usr/bin/gcc-4.2 /usr/bin/gcc)" \
    || die "No legacy C compiler found; set XNU_CC"
  cxx="$(select_compiler "${XNU_CXX:-}" /usr/bin/g++-4.0 /usr/bin/g++-4.2 /usr/bin/g++)" \
    || die "No legacy C++ compiler found; set XNU_CXX"
  check_i386_compiler "$cc" c
  check_i386_compiler "$cxx" c++

  log "Building RELEASE_I386 with hard kprintf checkpoints"
  (
    cd "$SOURCE_DIR"
    make -j "$JOBS" \
      ARCH_CONFIGS=I386 \
      KERNEL_CONFIGS=RELEASE \
      BUILD_STABS=1 \
      CC="$cc" \
      CXX="$cxx" \
      CTFCONVERT=/usr/bin/true \
      CTFMERGE=/usr/bin/true \
      CTFSCRUB=/usr/bin/true \
      exporthdrs all
  )

  built_kernel="$SOURCE_DIR/BUILD/obj/RELEASE_I386/mach_kernel"
  built_symbols="$SOURCE_DIR/BUILD/obj/RELEASE_I386/mach_kernel.sys"
  [[ -s "$built_kernel" ]] || die "XNU build completed without $built_kernel"
  "$ROOT_DIR/scripts/inspect_artifact.py" --binary "$built_kernel" --require-arch i386 --quiet
  strings "$built_kernel" | grep -q '\[XNU-TRACE IO23\]' \
    || die "Built kernel does not contain the trace markers"

  mkdir -p "$(dirname "$KERNEL_INPUT")" "$DIAGNOSTIC_OUTPUT"
  cp -p "$built_kernel" "$KERNEL_INPUT"
  cp -p "$built_kernel" "$DIAGNOSTIC_OUTPUT/mach_kernel.trace"
  if [[ -s "$built_symbols" ]]; then
    cp -p "$built_symbols" "$DIAGNOSTIC_OUTPUT/mach_kernel.trace.sys"
  fi
  log "Kernel SHA-256: $(sha256_file "$KERNEL_INPUT")"
  log "OpenCore custom-kernel input: $KERNEL_INPUT"
  log "Symbol-bearing build retained in: $DIAGNOSTIC_OUTPUT"
}

prepare_source
[[ "$ACTION" == "prepare" ]] || build_kernel
