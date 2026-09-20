#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
printf '[atom-kernel-qemu] compatibility wrapper: use qemu_boot_vanilla.sh or qemu_boot_atom.sh for explicit profiles\n' >&2
exec "$SCRIPT_DIR/qemu_boot_vanilla.sh" "$@"
