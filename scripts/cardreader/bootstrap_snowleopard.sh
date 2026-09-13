#!/usr/bin/env bash
set -Eeuo pipefail

XCODE_MEDIA=""
while (($#)); do
  case "$1" in
    --xcode-media)
      shift
      [[ $# -gt 0 ]] || { echo "--xcode-media needs a DMG or package path" >&2; exit 2; }
      XCODE_MEDIA="$1"
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  bootstrap_snowleopard.sh
  bootstrap_snowleopard.sh --xcode-media /path/to/Xcode_3.2.6.dmg
  bootstrap_snowleopard.sh --xcode-media /path/to/Xcode.mpkg

The script only installs Xcode when --xcode-media is supplied. Apple Developer
Tools are not downloaded automatically.
EOF
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '[snowleopard-bootstrap] %s\n' "$*"; }
die() { printf '[snowleopard-bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "must run on Darwin"
DARWIN_MAJOR="$(uname -r | cut -d. -f1)"
[[ "$DARWIN_MAJOR" == "10" ]] || die "expected Snow Leopard / Darwin 10, got $(sw_vers -productVersion 2>/dev/null || uname -r)"

find_xcodebuild() {
  if command -v xcodebuild >/dev/null 2>&1; then
    command -v xcodebuild
  elif [[ -x /Developer/usr/bin/xcodebuild ]]; then
    printf '%s\n' /Developer/usr/bin/xcodebuild
  else
    return 1
  fi
}

if ! XCODEBUILD="$(find_xcodebuild)"; then
  [[ -n "$XCODE_MEDIA" ]] || die "Xcode 3.2.x is missing. Re-run with --xcode-media /path/to/Xcode_3.2.6.dmg"
  [[ -e "$XCODE_MEDIA" ]] || die "Xcode media not found: $XCODE_MEDIA"

  PKG=""
  MOUNT=""
  case "$XCODE_MEDIA" in
    *.dmg|*.DMG)
      log "mounting $XCODE_MEDIA"
      ATTACH_OUT="$(hdiutil attach -nobrowse "$XCODE_MEDIA")"
      MOUNT="$(printf '%s\n' "$ATTACH_OUT" | awk '/\/Volumes\// {sub(/^.*\/Volumes\//,"/Volumes/"); print; exit}')"
      [[ -n "$MOUNT" && -d "$MOUNT" ]] || die "could not determine mounted Xcode volume"
      # Snow Leopard ships BSD find, which has no GNU -maxdepth.
      PKG="$(find "$MOUNT" \( -name 'Xcode.mpkg' -o -name '*Xcode*.mpkg' -o -name '*Xcode*.pkg' \) -print 2>/dev/null | head -1)"
      ;;
    *.mpkg|*.pkg)
      PKG="$XCODE_MEDIA"
      ;;
    *) die "unsupported Xcode media type: $XCODE_MEDIA" ;;
  esac

  [[ -n "$PKG" && -e "$PKG" ]] || die "could not find Xcode installer package"
  log "installing Apple Developer Tools from: $PKG"
  sudo installer -pkg "$PKG" -target /

  if [[ -n "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" || true
  fi

  XCODEBUILD="$(find_xcodebuild)" || die "Xcode installation completed but xcodebuild is still missing"
fi

[[ -d /Developer/SDKs/MacOSX10.6.sdk ]] || die "MacOSX10.6.sdk not found under /Developer/SDKs"
command -v gcc-4.2 >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || die "GCC from Xcode is missing"
command -v kextutil >/dev/null 2>&1 || die "kextutil is missing"
command -v plutil >/dev/null 2>&1 || die "plutil is missing"

log "xcodebuild: $XCODEBUILD"
"$XCODEBUILD" -version || true
log "SDK: /Developer/SDKs/MacOSX10.6.sdk"
log "Snow Leopard build host is ready"
