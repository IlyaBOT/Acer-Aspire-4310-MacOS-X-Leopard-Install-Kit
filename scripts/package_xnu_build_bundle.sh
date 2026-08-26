#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
XNU_BUILDER="$SCRIPT_DIR/build_xnu_trace.sh"
TOOLS_PREPARER="$SCRIPT_DIR/prepare_xnu_legacy_tools.sh"
DEFAULT_ARCHIVE="$ROOT_DIR/output/xnu-trace/aspire4310-xnu-build-vm.tar.gz"
ARCHIVE="$DEFAULT_ARCHIVE"
STAGING_DIR=""

usage() {
  cat <<'EOF'
Create an offline XNU build bundle for a Leopard/Snow Leopard VM.

Usage:
  scripts/package_xnu_build_bundle.sh [--output /path/to/bundle.tar.gz]

The bundle contains the patched pinned XNU tree, pinned Apple OSS host-tool sources,
the builders, the artifact inspector, and a short VM-side README. It contains no macOS,
Xcode, SDK, retail installer, or prebuilt third-party binaries.
EOF
}

log() { printf '[xnu-bundle] %s\n' "$*"; }
die() { printf '[xnu-bundle] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    case "$STAGING_DIR" in
      /tmp/aspire4310-xnu-bundle.*|"${TMPDIR:-/tmp}"/aspire4310-xnu-bundle.*)
        rm -rf -- "$STAGING_DIR"
        ;;
      *) log "Refusing to clean unexpected temporary directory: $STAGING_DIR" ;;
    esac
  fi
}
trap cleanup EXIT INT TERM

while (($#)); do
  case "$1" in
    --output)
      (($# > 1)) || die "--output requires a path"
      shift
      ARCHIVE="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

command -v tar >/dev/null 2>&1 || die "tar is required"
"$XNU_BUILDER" --prepare-only
"$TOOLS_PREPARER" --prepare-only

case "$ARCHIVE" in
  /*) ;;
  *) ARCHIVE="$PWD/$ARCHIVE" ;;
esac
mkdir -p "$(dirname "$ARCHIVE")"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aspire4310-xnu-bundle.XXXXXX")"
BUNDLE_ROOT="$STAGING_DIR/Aspire4310-XNU-Build"
mkdir -p "$BUNDLE_ROOT/scripts" "$BUNDLE_ROOT/patches" "$BUNDLE_ROOT/cache/xnu-trace" \
  "$BUNDLE_ROOT/cache/xnu-toolchain-sources" "$BUNDLE_ROOT/input/kernels/leopard" \
  "$BUNDLE_ROOT/output"

cp -p "$XNU_BUILDER" "$BUNDLE_ROOT/scripts/"
cp -p "$TOOLS_PREPARER" "$BUNDLE_ROOT/scripts/"
cp -p "$SCRIPT_DIR/inspect_artifact.py" "$BUNDLE_ROOT/scripts/"
cp -p "$ROOT_DIR/patches/xnu-1228.5.20-startup-trace.patch" "$BUNDLE_ROOT/patches/"
cp -R "$ROOT_DIR/cache/xnu-trace/xnu-1228.5.20" "$BUNDLE_ROOT/cache/xnu-trace/"
cp -R "$ROOT_DIR/cache/xnu-toolchain-sources"/. "$BUNDLE_ROOT/cache/xnu-toolchain-sources/"
printf '%s\n' 'f3fe36d86c12b679329ee4b45af0fc971368bf18' \
  > "$BUNDLE_ROOT/cache/xnu-trace/xnu-1228.5.20/.aspire4310-xnu-commit"

while IFS='|' read -r component commit; do
  printf '%s\n' "$commit" \
    > "$BUNDLE_ROOT/cache/xnu-toolchain-sources/$component/.aspire4310-source-commit"
done <<'EOF'
bootstrap_cmds|df26aea3728854ec94a438b2bff58306d457cfef
Libstreams|2fc9581ce7dca3e157f5529af4ed25cfd513a4be
cctools|18acda4142e5a43362d44d3a5a01665e8c7d80e1
IOKitUser|0b6712423a745bdab1ce83bb35ca500629f8314b
kext_tools|fc58a4f7334f7c09552c7a080e1ea2eeb1299df3
developer_cmds|2a55f1bd0d1ca529e7bb6728a872de2ffa1d1a92
EOF

cat > "$BUNDLE_ROOT/README-VM.txt" <<'EOF'
Aspire 4310 XNU 1228.5.20 offline build bundle

Prerequisite: Leopard/Snow Leopard VM with Xcode 3.x installed under /Developer.

1. Verify that /bin/csh, /usr/bin/mig, /usr/bin/gnutar and gcc exist.
2. Verify the offline source provenance markers:
     ./scripts/prepare_xnu_legacy_tools.sh --verify-only
3. Install the pinned Apple OSS host tools:
     ./scripts/prepare_xnu_legacy_tools.sh --install
4. Build the patched RELEASE_I386 kernel:
     ./scripts/build_xnu_trace.sh
5. Copy input/kernels/leopard/kernel back to the main project checkout.
   The symbol-bearing image is retained under output/xnu-trace/.
EOF

rm -f -- "$ARCHIVE"
tar -czf "$ARCHIVE" -C "$STAGING_DIR" Aspire4310-XNU-Build
[[ -s "$ARCHIVE" ]] || die "Bundle was not created: $ARCHIVE"

if command -v shasum >/dev/null 2>&1; then
  CHECKSUM="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
else
  CHECKSUM="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
fi
log "Bundle: $ARCHIVE"
log "SHA-256: $CHECKSUM"
