#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MAIN_BUILDER="$ROOT_DIR/prepare_aspire4310_macos.sh"
VM_DIR="$ROOT_DIR/output/xnu-qemu-vm"
VM_DISK="$VM_DIR/leopard-build.qcow2"
VM_ESP="$VM_DIR/ESP"
ACTION=""
INSTALLER=""
GUEST_MEDIA=()
ACCELERATOR="${XNU_QEMU_ACCEL:-tcg}"
MEMORY_MB="${XNU_QEMU_MEMORY_MB:-2048}"
DISK_GB="${XNU_QEMU_DISK_GB:-24}"
SSH_PORT="${XNU_QEMU_SSH_PORT:-2222}"

usage() {
  cat <<'EOF'
Create or run the isolated Leopard XNU build VM with QEMU.

Usage:
  scripts/xnu_qemu_vm.sh --create --iso "/path/to/Leopard.iso"
  scripts/xnu_qemu_vm.sh --start [--iso "/path/to/Leopard.iso"] \
    [--guest-media "/path/to/update-or-developer-dvd.dmg"]... [--accel tcg|hvf]

Guest media is attached read-only. Apple DMG images use QEMU's read-only dmg
driver; ISO and CDR images use the raw driver. At most two optical images can
be attached, including the optional Leopard installer.

The default accelerator is TCG. Upstream QEMU has a reproducible report of 10.6.8
rebooting under HVF while the same guest boots under TCG. Try HVF only as an A/B test.

Environment overrides:
  XNU_QEMU_MEMORY_MB=2048
  XNU_QEMU_DISK_GB=24
  XNU_QEMU_SSH_PORT=2222
EOF
}

log() { printf '[xnu-qemu] %s\n' "$*"; }
die() { printf '[xnu-qemu] ERROR: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --create) [[ -z "$ACTION" ]] || die "Choose one action"; ACTION="create" ;;
    --start) [[ -z "$ACTION" ]] || die "Choose one action"; ACTION="start" ;;
    --iso)
      (($# > 1)) || die "--iso requires a path"
      shift
      INSTALLER="$1"
      ;;
    --guest-media)
      (($# > 1)) || die "--guest-media requires a path"
      shift
      GUEST_MEDIA+=("$1")
      ;;
    --accel)
      (($# > 1)) || die "--accel requires tcg or hvf"
      shift
      ACCELERATOR="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$ACTION" ]] || { usage; exit 1; }
case "$ACCELERATOR" in tcg|hvf) ;; *) die "--accel must be tcg or hvf" ;; esac
[[ "$MEMORY_MB" =~ ^[1-9][0-9]*$ ]] || die "XNU_QEMU_MEMORY_MB must be positive"
[[ "$DISK_GB" =~ ^[1-9][0-9]*$ ]] || die "XNU_QEMU_DISK_GB must be positive"
[[ "$SSH_PORT" =~ ^[1-9][0-9]*$ ]] || die "XNU_QEMU_SSH_PORT must be positive"
[[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] || die "Run this VM helper on the Intel Mac host"
[[ "$(uname -m 2>/dev/null || true)" == "x86_64" ]] || die "This profile requires an Intel Mac host"

find_host_tool() {
  local tool="$1" resolved candidate
  resolved="$(command -v "$tool" || true)"
  if [[ -n "$resolved" && -x "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return
  fi
  for candidate in "/opt/local/bin/$tool" "/usr/local/bin/$tool" "/opt/homebrew/bin/$tool"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

QEMU_SYSTEM="$(find_host_tool qemu-system-x86_64 || true)"
QEMU_IMG="$(find_host_tool qemu-img || true)"
[[ -x "$QEMU_SYSTEM" && -x "$QEMU_IMG" ]] \
  || die "QEMU is missing. On macOS 12 install MacPorts, then run: sudo /opt/local/bin/port install qemu"

find_ia32_firmware() {
  local candidate qemu_prefix
  qemu_prefix="$(cd -- "$(dirname -- "$QEMU_SYSTEM")/.." && pwd -P)"
  for candidate in \
    "$qemu_prefix/share/qemu/edk2-i386-code.fd" \
    /usr/local/share/qemu/edk2-i386-code.fd \
    /opt/homebrew/share/qemu/edk2-i386-code.fd; do
    if [[ -s "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

FIRMWARE="$(find_ia32_firmware)" \
  || die "QEMU IA32 EDK2 firmware (edk2-i386-code.fd) was not found"

if [[ -n "$INSTALLER" ]]; then
  [[ "$INSTALLER" != *$'\n'* ]] || die "Installer path must not contain a newline"
  [[ "$INSTALLER" != *,* ]] || die "Installer path must not contain a comma"
  [[ -f "$INSTALLER" ]] || die "Installer image not found: $INSTALLER"
  INSTALLER="$(cd -- "$(dirname -- "$INSTALLER")" && pwd -P)/$(basename -- "$INSTALLER")"
fi

normalize_guest_media() {
  local index path
  for ((index = 0; index < ${#GUEST_MEDIA[@]}; index++)); do
    path="${GUEST_MEDIA[$index]}"
    [[ "$path" != *$'\n'* ]] || die "Guest-media path must not contain a newline"
    [[ "$path" != *,* ]] || die "Guest-media path must not contain a comma"
    [[ -f "$path" ]] || die "Guest media not found: $path"
    GUEST_MEDIA[index]="$(cd -- "$(dirname -- "$path")" && pwd -P)/$(basename -- "$path")"
  done
}

guest_media_format() {
  case "$1" in
    *.dmg|*.DMG) printf '%s\n' dmg ;;
    *.iso|*.ISO|*.cdr|*.CDR) printf '%s\n' raw ;;
    *) die "Unsupported guest-media extension (use DMG, ISO, or CDR): $1" ;;
  esac
}

normalize_guest_media

select_machine() {
  if "$QEMU_SYSTEM" -machine help 2>/dev/null | grep -q 'pc-i440fx-2\.11'; then
    printf '%s\n' 'pc-i440fx-2.11'
  else
    printf '%s\n' 'pc-i440fx'
  fi
}

create_vm() {
  [[ -n "$INSTALLER" ]] || die "--create requires --iso /path/to/Leopard.iso"
  [[ ! -e "$VM_DIR" ]] || die "VM already exists: $VM_DIR"

  log "Building a minimal IA32 OpenCore/FakeSMC boot volume for QEMU"
  "$MAIN_BUILDER" --build \
    --os leopard \
    --bootloader opencore \
    --oc-arch ia32 \
    --hfs-driver 32 \
    --kernel vanilla \
    --boot-preset verbose \
    --kext-set smc \
    --sata native \
    --acpi native \
    --apic native \
    --runtime legacy

  local built_esp="$ROOT_DIR/output/leopard/opencore-vanilla/ESP"
  [[ -f "$built_esp/EFI/BOOT/BOOTIA32.efi" ]] \
    || die "The IA32 OpenCore build did not produce BOOTIA32.efi"
  mkdir -p "$VM_DIR"
  cp -R "$built_esp" "$VM_ESP"
  "$QEMU_IMG" create -f qcow2 "$VM_DISK" "${DISK_GB}G"
  printf '%s\n' "$INSTALLER" > "$VM_DIR/installer.path"
  log "Created: $VM_DISK"
  log "Start the installer with:"
  printf '  %q --start --iso %q\n' "$0" "$INSTALLER"
}

start_vm() {
  [[ -s "$VM_DISK" ]] || die "VM disk does not exist; run --create first"
  [[ -f "$VM_ESP/EFI/BOOT/BOOTIA32.efi" ]] || die "VM OpenCore ESP is incomplete"

  local machine media media_format
  local cd_index=2
  local -a args
  machine="$(select_machine)"
  args=(
    -name "Aspire4310 XNU Build VM"
    -machine "$machine,accel=$ACCELERATOR"
    -cpu "Penryn,vendor=GenuineIntel"
    -smp 1
    -m "$MEMORY_MB"
    -bios "$FIRMWARE"
    -boot menu=on
    -drive "file=fat:rw:$VM_ESP,format=raw,if=ide,index=0,media=disk"
    -drive "file=$VM_DISK,format=qcow2,if=ide,index=1,media=disk"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    -device "e1000,netdev=net0"
    -usb
    -device usb-kbd
    -device usb-tablet
    -display cocoa
    -no-reboot
  )
  if [[ -n "$INSTALLER" ]]; then
    [[ -f "$INSTALLER" ]] || die "Installer image not found: $INSTALLER"
    args+=( -drive "file=$INSTALLER,format=raw,if=ide,index=$cd_index,media=cdrom,readonly=on" )
    cd_index=$((cd_index + 1))
  fi
  for media in "${GUEST_MEDIA[@]}"; do
    (( cd_index <= 3 )) || die "The i440fx IDE profile supports at most two optical images"
    media_format="$(guest_media_format "$media")"
    "$QEMU_IMG" info -f "$media_format" "$media" >/dev/null \
      || die "QEMU cannot read guest media as $media_format: $media"
    args+=( -drive "file=$media,format=$media_format,if=ide,index=$cd_index,media=cdrom,readonly=on" )
    cd_index=$((cd_index + 1))
  done
  log "Starting QEMU with $machine/$ACCELERATOR; host SSH forward is 127.0.0.1:$SSH_PORT"
  "$QEMU_SYSTEM" "${args[@]}"
}

case "$ACTION" in
  create) create_vm ;;
  start) start_vm ;;
esac
