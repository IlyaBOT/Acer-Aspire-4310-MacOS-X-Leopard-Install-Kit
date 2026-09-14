#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_HOMEBREW=0
if [[ "${1:-}" == "--install-homebrew" ]]; then
  INSTALL_HOMEBREW=1
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--install-homebrew]" >&2
  exit 2
fi

log() { printf '[cardreader-bootstrap] %s\n' "$*"; }
die() { printf '[cardreader-bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "this script is for macOS"
log "macOS $(sw_vers -productVersion)"

if ! xcode-select -p >/dev/null 2>&1; then
  log "Xcode Command Line Tools are missing; opening Apple's installer"
  xcode-select --install || true
  die "finish Command Line Tools installation, then run this script again"
fi

# If both tools already exist, Homebrew is unnecessary.
if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    if [[ "$INSTALL_HOMEBREW" -eq 0 ]]; then
      die "git/python3 are incomplete and Homebrew is missing. Re-run with --install-homebrew."
    fi
    command -v curl >/dev/null 2>&1 || die "curl is required to bootstrap Homebrew"
    log "installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x /usr/local/bin/brew ]]; then
      export PATH="/usr/local/bin:$PATH"
    elif [[ -x /opt/homebrew/bin/brew ]]; then
      export PATH="/opt/homebrew/bin:$PATH"
    fi
  fi

  command -v brew >/dev/null 2>&1 || die "Homebrew installed but is not on PATH"

  PACKAGES=()
  command -v git >/dev/null 2>&1 || PACKAGES+=(git)
  command -v python3 >/dev/null 2>&1 || PACKAGES+=(python)
  if ((${#PACKAGES[@]})); then
    log "installing: ${PACKAGES[*]}"
    brew install "${PACKAGES[@]}"
  fi
fi

command -v git >/dev/null 2>&1 || die "git is still missing"
command -v python3 >/dev/null 2>&1 || die "python3 is still missing"

log "git: $(git --version)"
log "python: $(python3 --version 2>&1)"
log "source-preparation host is ready"

cat <<'EOF'

NOTE: macOS 12 is used only to fetch/patch/package the source.
The target is a Darwin 10 / i386 kernel extension. Modern Xcode no longer ships
an i386-capable 10.6 KEXT SDK/toolchain, while the upstream project is an Xcode
3.2 project. Build the KEXT on Snow Leopard with Xcode 3.2.x using
build_snowleopard.sh.
EOF
