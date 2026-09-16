#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
IMAGE="${1:-}"
QEMU_BIN="${QEMU_BIN:-}"
QEMU_CPU="${QEMU_CPU:-Penryn}"
QEMU_MEM="${QEMU_MEM:-2048}"
QEMU_SMP="${QEMU_SMP:-2}"
LOG_DIR="$ROOT_DIR/artifacts/qemu"

log() { printf '[atom-kernel-qemu] %s\n' "$*"; }
die() { printf '[atom-kernel-qemu] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -n "$IMAGE" ] || die "usage: $0 /path/to/full-raw-test-disk.img"
[ -f "$IMAGE" ] || die "disk image not found: $IMAGE"

if [ -z "$QEMU_BIN" ]; then
  if have qemu-system-x86_64; then
    QEMU_BIN="$(command -v qemu-system-x86_64)"
  elif have qemu-system-i386; then
    QEMU_BIN="$(command -v qemu-system-i386)"
  else
    die "qemu-system-x86_64 or qemu-system-i386 is required"
  fi
fi

mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
QLOG="$LOG_DIR/qemu-$STAMP.log"

log "control CPU: $QEMU_CPU"
log "RAM: ${QEMU_MEM} MiB, SMP: $QEMU_SMP"
log "disk: $IMAGE"
log "QEMU internal log: $QLOG"
log "snapshot mode is enabled; QEMU will not persist guest writes to the image"
log "this is a supported-CPU build/toolchain control test, not an Atom emulation test"

exec "$QEMU_BIN" \
  -machine pc,accel=tcg \
  -cpu "$QEMU_CPU",vendor=GenuineIntel \
  -m "$QEMU_MEM" \
  -smp "$QEMU_SMP" \
  -drive "file=$IMAGE,format=raw,if=ide,index=0" \
  -boot c \
  -vga std \
  -snapshot \
  -no-reboot \
  -no-shutdown \
  -monitor none \
  -serial "file:$LOG_DIR/serial-$STAMP.log" \
  -d guest_errors,cpu_reset \
  -D "$QLOG"
