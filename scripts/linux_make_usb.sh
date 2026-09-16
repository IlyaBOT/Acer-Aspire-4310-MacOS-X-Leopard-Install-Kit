#!/usr/bin/env bash
# Linux legacy macOS USB backend entrypoint.
# Routes --update-efi through the robust non-interactive updater while preserving
# the original backend for --make-usb, --verify, --inspect-retail and --list-disks.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

for arg in "$@"; do
  if [[ "$arg" == "--update-efi" ]]; then
    exec bash "$SCRIPT_DIR/linux_update_efi.sh" "$@"
  fi
done

exec bash "$SCRIPT_DIR/linux_make_usb_legacy.sh" "$@"
