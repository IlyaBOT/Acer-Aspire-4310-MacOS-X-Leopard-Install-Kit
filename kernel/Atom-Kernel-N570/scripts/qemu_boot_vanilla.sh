#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DEFAULT_IMAGE="$ROOT_DIR/artifacts/qemu/asus1215p-vanilla-esp.raw"
IMAGE="${1:-$DEFAULT_IMAGE}"
INSTALLER_ISO="${2:-${QEMU_INSTALLER_ISO:-}}"
QEMU_BIN="${QEMU_BIN:-}"
QEMU_IMG_BIN="${QEMU_IMG_BIN:-}"
QEMU_CPU="${QEMU_CPU:-Penryn}"
QEMU_MEM="${QEMU_MEM:-1024}"
QEMU_SMP="${QEMU_SMP:-1}"
QEMU_ACCEL="${QEMU_ACCEL:-tcg}"
REUSE_OVERLAY="${QEMU_REUSE_OVERLAY:-0}"
VM_DIR="$ROOT_DIR/artifacts/qemu/vanilla-penryn"

log() { printf '[qemu-vanilla-penryn] %s\n' "$*"; }
die() { printf '[qemu-vanilla-penryn] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    die "root privileges are required to install QEMU, but sudo is unavailable"
  fi
}

find_qemu() {
  if [ -n "$QEMU_BIN" ] && [ -x "$QEMU_BIN" ]; then
    return 0
  fi
  if have qemu-system-x86_64; then
    QEMU_BIN="$(command -v qemu-system-x86_64)"
    return 0
  fi
  if have qemu-system-i386; then
    QEMU_BIN="$(command -v qemu-system-i386)"
    return 0
  fi
  return 1
}

find_qemu_img() {
  if [ -n "$QEMU_IMG_BIN" ] && [ -x "$QEMU_IMG_BIN" ]; then
    return 0
  fi
  if have qemu-img; then
    QEMU_IMG_BIN="$(command -v qemu-img)"
    return 0
  fi
  return 1
}

install_qemu() {
  [ "${QEMU_AUTO_INSTALL:-1}" = "1" ] || die "QEMU is missing and QEMU_AUTO_INSTALL=0"
  OS="$(uname -s 2>/dev/null || printf unknown)"
  case "$OS" in
    Darwin)
      if have brew; then
        log "QEMU not found; installing with Homebrew"
        brew install qemu
      elif have port; then
        log "QEMU not found; installing with MacPorts"
        run_root port install qemu
      else
        die "QEMU is missing. Install Homebrew or MacPorts, then install qemu"
      fi
      ;;
    Linux)
      if have apt-get; then
        log "QEMU not found; installing with apt"
        run_root apt-get update
        run_root apt-get install -y qemu-system-x86 qemu-utils
      elif have dnf; then
        log "QEMU not found; installing with dnf"
        run_root dnf install -y qemu-system-x86 qemu-img
      elif have pacman; then
        log "QEMU not found; installing with pacman"
        run_root pacman -S --needed --noconfirm qemu-system-x86 qemu-img
      elif have zypper; then
        log "QEMU not found; installing with zypper"
        run_root zypper --non-interactive install qemu
      else
        die "QEMU is missing and no supported package manager was found"
      fi
      ;;
    *) die "automatic QEMU installation is only implemented for macOS and Linux" ;;
  esac
}

if ! find_qemu || ! find_qemu_img; then
  install_qemu
  find_qemu || die "QEMU installation completed, but qemu-system-x86_64/i386 is still not in PATH"
  find_qemu_img || die "QEMU installation completed, but qemu-img is still not in PATH"
fi

[ -f "$IMAGE" ] || die "prepared ESP boot image not found: $IMAGE\nCreate it with prepare_qemu_esp_linux.sh / prepare_qemu_esp_windows.ps1"
BASE_IMAGE="$(cd "$(dirname "$IMAGE")" && pwd -P)/$(basename "$IMAGE")"

if [ -n "$INSTALLER_ISO" ]; then
  [ -f "$INSTALLER_ISO" ] || die "Snow Leopard installer ISO not found: $INSTALLER_ISO"
  INSTALLER_ISO="$(cd "$(dirname "$INSTALLER_ISO")" && pwd -P)/$(basename "$INSTALLER_ISO")"
fi

mkdir -p "$VM_DIR"
OVERLAY="$VM_DIR/disk.qcow2"
BACKING_MARKER="$VM_DIR/backing-image.txt"
FORMAT="$($QEMU_IMG_BIN info "$BASE_IMAGE" 2>/dev/null | awk '/^file format: / { print $3; exit }')"
[ -n "$FORMAT" ] || die "could not determine image format with qemu-img: $BASE_IMAGE"

if [ "$REUSE_OVERLAY" != "1" ] || [ ! -f "$OVERLAY" ] || [ ! -f "$BACKING_MARKER" ] || [ "$(cat "$BACKING_MARKER" 2>/dev/null || true)" != "$BASE_IMAGE" ]; then
  rm -f "$OVERLAY"
  log "creating disposable qcow2 overlay over $FORMAT base image"
  "$QEMU_IMG_BIN" create -q -f qcow2 -F "$FORMAT" -b "$BASE_IMAGE" "$OVERLAY"
  printf '%s\n' "$BASE_IMAGE" > "$BACKING_MARKER"
else
  log "reusing existing overlay: $OVERLAY"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
SERIAL_LOG="$VM_DIR/serial-$STAMP.log"
QEMU_LOG="$VM_DIR/qemu-$STAMP.log"

log "QEMU: $QEMU_BIN"
log "CPU: $QEMU_CPU, vCPU: $QEMU_SMP, RAM: ${QEMU_MEM} MiB, accelerator: $QEMU_ACCEL"
log "machine: legacy PC/i440FX-class, IDE disk, std VGA, USB keyboard/tablet"
log "network: disabled; audio: disabled"
log "ESP boot image: $BASE_IMAGE"
if [ -n "$INSTALLER_ISO" ]; then log "Snow Leopard DVD ISO: $INSTALLER_ISO"; else log "Snow Leopard DVD ISO: not attached"; fi
log "overlay: $OVERLAY"
log "serial log: $SERIAL_LOG"
log "QEMU log: $QEMU_LOG"
log "expected guest payload: vanilla self-built Darwin 10.3.0 kernel"

EXTRA_ARGS=()
if [ -n "$INSTALLER_ISO" ]; then EXTRA_ARGS+=( -cdrom "$INSTALLER_ISO" ); fi

exec "$QEMU_BIN" \
  -name "SnowLeopard-Vanilla-Penryn" \
  -machine "pc,accel=$QEMU_ACCEL" \
  -cpu "$QEMU_CPU,vendor=GenuineIntel" \
  -m "$QEMU_MEM" \
  -smp "$QEMU_SMP" \
  -drive "file=$OVERLAY,format=qcow2,if=ide,index=0" \
  "${EXTRA_ARGS[@]}" \
  -boot c \
  -vga std \
  -usb \
  -device usb-kbd \
  -device usb-tablet \
  -nic none \
  -audiodev none,id=noaudio \
  -monitor none \
  -serial "file:$SERIAL_LOG" \
  -no-reboot \
  -no-shutdown \
  -d guest_errors,cpu_reset \
  -D "$QEMU_LOG"
