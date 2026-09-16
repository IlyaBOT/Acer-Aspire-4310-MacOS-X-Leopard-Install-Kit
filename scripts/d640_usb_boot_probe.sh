#!/usr/bin/env bash
set -Eeuo pipefail

DISK=""
CASE_ID=""
ALLOW_INTERNAL=0
TMP=""
PART=""

log() { printf '[d640-boot-probe] %s\n' "$*"; }
die() { printf '[d640-boot-probe] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  set +e
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'USAGE'
Destructive legacy-BIOS USB boot probe for the eMachines D640.

This intentionally does NOT boot an OS. It creates tiny real-mode boot sectors
that print a marker and halt, so BIOS -> MBR -> partition-PBR handoff can be
tested independently of OpenCore, GRUB, Linux, or macOS.

Usage:
  sudo bash scripts/d640_usb_boot_probe.sh --disk /dev/sdX --case CASE
  bash scripts/d640_usb_boot_probe.sh --list
  bash scripts/d640_usb_boot_probe.sh --doctor

Options:
  --disk /dev/sdX       whole USB disk; ALL DATA WILL BE DESTROYED
  --case CASE           one case from --list
  --allow-internal      permit a disk that Linux does not identify as USB/removable

The probe uses a 128 MiB boot partition for normal MBR cases. This keeps the
filesystem and CHS/LBA edge cases small and removes OS size as a variable.
USAGE
}

list_cases() {
  cat <<'CASES'
Recommended order:
  mbr-direct            MBR, active FAT16 partition #1, start LBA 63; MBR prints directly
  mbr-fat16-63          MBR -> FAT16 PBR via INT13 extensions (LBA), type 0x06, start 63
  mbr-fat16-63-chs      same layout, but MBR reads the PBR via classic CHS INT13 AH=02
  mbr-fat16-lba63       FAT16 type 0x0E, start 63, LBA read
  mbr-fat32-63          FAT32 type 0x0B, start 63, LBA read
  mbr-fat32-63-chs      same FAT32 layout, classic CHS read
  mbr-fat32-lba63       FAT32 type 0x0C, start 63, LBA read
  mbr-ntfs-63           NTFS type 0x07, start 63, LBA read
  mbr-ntfs-63-chs       same NTFS layout, classic CHS read
  mbr-fat16-2048        MBR -> FAT16 PBR, type 0x0E, start LBA 2048
  mbr-fat32-2048        MBR -> FAT32 PBR, type 0x0C, start LBA 2048
  mbr-ntfs-2048         MBR -> NTFS PBR, type 0x07, start LBA 2048 (Win7-like layout)
  usbzip-fat16          ZIP geometry 64 heads / 32 sectors, active partition #4, FAT16
  usbzip-fat32          same ZIP geometry but FAT32 (control experiment)
  superfloppy-fat32     no partition table; FAT32 boot sector at LBA 0
  superfloppy-ntfs      no partition table; NTFS boot sector at LBA 0

Interpretation for partitioned cases:
  "D640 MBR ..." only      BIOS executed MBR; MBR could not reach/execute the PBR.
  "D640 PBR ... OK"        BIOS -> MBR -> PBR handoff works for this layout/filesystem.
  blinking cursor/no text  firmware did not reach our MBR marker or froze before it.

For superfloppy cases only the PBR marker is expected.
CASES
}

doctor() {
  local c
  for c in bash lsblk findmnt sfdisk blockdev dd wipefs mkfs.fat nasm; do
    if have "$c"; then printf 'OK      %s\n' "$c"; else printf 'MISSING %s\n' "$c"; fi
  done
  if have mkfs.ntfs; then printf 'OK      mkfs.ntfs\n'; else printf 'MISSING mkfs.ntfs (package: ntfs-3g)\n'; fi
  if have mkdiskimage; then printf 'OK      mkdiskimage\n'; else printf 'MISSING mkdiskimage (package: syslinux-utils; needed only for usbzip-*)\n'; fi
}

need_value() { [[ $# -gt 1 ]] || die "$1 requires a value"; }

if [[ $# -eq 0 ]]; then usage; exit 2; fi
while (($#)); do
  case "$1" in
    --disk) need_value "$@"; shift; DISK="$1" ;;
    --case) need_value "$@"; shift; CASE_ID="$1" ;;
    --allow-internal) ALLOW_INTERNAL=1 ;;
    --list) list_cases; exit 0 ;;
    --doctor) doctor; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

case "$CASE_ID" in
  mbr-direct|mbr-fat16-63|mbr-fat16-63-chs|mbr-fat16-lba63|mbr-fat32-63|mbr-fat32-63-chs|mbr-fat32-lba63|mbr-ntfs-63|mbr-ntfs-63-chs|mbr-fat16-2048|mbr-fat32-2048|mbr-ntfs-2048|usbzip-fat16|usbzip-fat32|superfloppy-fat32|superfloppy-ntfs) ;;
  "") die "--case is required (see --list)" ;;
  *) die "Unknown case: $CASE_ID (see --list)" ;;
esac

[[ $EUID -eq 0 ]] || die "Run the destructive probe as root"
[[ -n "$DISK" && -b "$DISK" ]] || die "--disk must be a block device"
[[ "$(lsblk -dnro TYPE "$DISK")" == disk ]] || die "Whole disk required, not a partition"

root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
root_parent=""
if [[ -n "$root_source" && -b "$root_source" ]]; then
  root_parent="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
  [[ -n "$root_parent" ]] && root_parent="/dev/$root_parent"
fi
[[ "$DISK" != "$root_source" && "$DISK" != "$root_parent" ]] || die "Refusing Linux root disk: $DISK"

rm_flag="$(lsblk -dnro RM "$DISK" | tr -d ' ')"
transport="$(lsblk -dnro TRAN "$DISK" | tr -d ' ')"
if [[ $ALLOW_INTERNAL -ne 1 && "$rm_flag" != 1 && "$transport" != usb ]]; then
  die "$DISK is not clearly removable/USB (RM=$rm_flag TRAN=${transport:-unknown}); use --allow-internal only after manual verification"
fi

for c in lsblk findmnt sfdisk blockdev dd wipefs mkfs.fat nasm; do have "$c" || die "Missing required command: $c"; done
case "$CASE_ID" in
  *ntfs*) have mkfs.ntfs || die "NTFS cases require mkfs.ntfs (usually package ntfs-3g)" ;;
esac
case "$CASE_ID" in
  usbzip-*) have mkdiskimage || die "USB-ZIP cases require mkdiskimage (usually package syslinux-utils)" ;;
esac

TMP="$(mktemp -d /tmp/d640-usb-probe.XXXXXX)"

unmount_children() {
  local mp
  while IFS= read -r mp; do
    [[ -n "$mp" ]] || continue
    umount "$mp" 2>/dev/null || true
  done < <(lsblk -lnpo MOUNTPOINTS "$DISK" | awk 'NF')
}

settle() {
  have partprobe && partprobe "$DISK" >/dev/null 2>&1 || true
  have udevadm && udevadm settle || true
  sleep 1
}

confirm_erase() {
  local expected="ERASE $DISK FOR $CASE_ID" answer
  printf 'WARNING: this destroys all data on %s.\n' "$DISK"
  lsblk -o NAME,PATH,SIZE,MODEL,TRAN,RM,FSTYPE,LABEL,MOUNTPOINTS "$DISK"
  printf 'Type exactly: %s\n> ' "$expected"
  IFS= read -r answer
  [[ "$answer" == "$expected" ]] || die "Confirmation mismatch; nothing changed"
}

wipe_disk() {
  unmount_children
  wipefs -a -f "$DISK" >/dev/null 2>&1 || true
  dd if=/dev/zero of="$DISK" bs=1M count=4 conv=fsync status=none
  sync
  settle
}

compile_direct_mbr() {
  local out="$1"
  cat > "$TMP/mbr-direct.asm" <<'ASM'
bits 16
org 0x7c00
start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    sti
    mov si, msg
.puts:
    lodsb
    test al, al
    jz .hang
    mov ah, 0x0e
    mov bx, 0x0007
    int 0x10
    jmp .puts
.hang:
    cli
    hlt
    jmp .hang
msg db 13,10,'D640 MBR DIRECT OK',13,10,0
times 446-($-$$) db 0
ASM
  nasm -f bin "$TMP/mbr-direct.asm" -o "$out"
  [[ "$(stat -c %s "$out")" -eq 446 ]] || die "Internal error: direct MBR is not 446 bytes"
}

compile_chain_mbr() {
  local out="$1" tag="$2" mode="${3:-lba}"
  local read_block
  if [[ "$mode" == chs ]]; then
    read_block='
    mov dh, [bx+1]
    mov cl, [bx+2]
    mov ch, [bx+3]
    mov dl, [bootdrv]
    mov bx, 0x0600
    mov ax, 0x0201
    int 0x13
'
  else
    read_block='
    mov si, 0x0500
    mov byte [si+0], 0x10
    mov byte [si+1], 0x00
    mov word [si+2], 0x0001
    mov word [si+4], 0x0600
    mov word [si+6], 0x0000
    mov ax, [bx+8]
    mov [si+8], ax
    mov ax, [bx+10]
    mov [si+10], ax
    xor ax, ax
    mov [si+12], ax
    mov [si+14], ax
    mov dl, [bootdrv]
    mov ah, 0x42
    int 0x13
'
  fi
  cat > "$TMP/mbr-chain.asm" <<ASM
bits 16
org 0x7c00
start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    sti
    mov [bootdrv], dl
    mov si, msg
    call puts

    mov bx, 0x7dbe
    mov cx, 4
.find:
    cmp byte [bx], 0x80
    je .found
    add bx, 16
    loop .find
    mov si, noactive
    call puts
    jmp hang

.found:
$read_block
    jc .diskerr
    jmp 0x0000:0x0600

.diskerr:
    mov si, diskerr
    call puts
hang:
    cli
    hlt
    jmp hang

puts:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0e
    mov bx, 0x0007
    int 0x10
    jmp puts
.done:
    ret

bootdrv db 0
msg db 13,10,'D640 MBR ${tag}-${mode}',13,10,0
noactive db 'NO ACTIVE PARTITION',13,10,0
diskerr db 'INT13 READ ERROR',13,10,0
times 446-(\$-\$\$) db 0
ASM
  nasm -f bin "$TMP/mbr-chain.asm" -o "$out"
  [[ "$(stat -c %s "$out")" -eq 446 ]] || die "Internal error: chain MBR is not 446 bytes"
}

compile_pbr_code() {
  local offset="$1" out="$2" tag="$3"
  cat > "$TMP/pbr.asm" <<ASM
bits 16
start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    sti
    call .here
.here:
    pop si
    add si, msg-.here
.puts:
    lodsb
    test al, al
    jz .hang
    mov ah, 0x0e
    mov bx, 0x0007
    int 0x10
    jmp .puts
.hang:
    cli
    hlt
    jmp .hang
msg db 13,10,'D640 PBR ${tag} OK',13,10,0
ASM
  nasm -f bin "$TMP/pbr.asm" -o "$out"
  local max=$((510 - offset)) actual
  actual="$(stat -c %s "$out")"
  (( actual <= max )) || die "Internal error: PBR code too large ($actual > $max)"
}

preflight_asm() {
  compile_direct_mbr "$TMP/preflight-direct.bin"
  compile_chain_mbr "$TMP/preflight-lba.bin" SELFTEST lba
  compile_chain_mbr "$TMP/preflight-chs.bin" SELFTEST chs
  compile_pbr_code 62 "$TMP/preflight-pbr.bin" SELFTEST
}

write_mbr_code() {
  local file="$1"
  dd if="$file" of="$DISK" bs=1 count=446 conv=notrunc,fsync status=none
  printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 count=2 conv=notrunc,fsync status=none
}

patch_pbr() {
  local dev="$1" fs="$2" tag="$3" offset jump code
  case "$fs" in
    fat16) offset=62; jump=$'\xeb\x3c\x90' ;;
    fat32) offset=90; jump=$'\xeb\x58\x90' ;;
    ntfs)  offset=84; jump=$'\xeb\x52\x90' ;;
    *) die "Internal error: unknown filesystem $fs" ;;
  esac
  code="$TMP/pbr-${fs}.bin"
  compile_pbr_code "$offset" "$code" "$tag"
  printf '%s' "$jump" | dd of="$dev" bs=1 seek=0 count=3 conv=notrunc,fsync status=none
  dd if="$code" of="$dev" bs=1 seek="$offset" conv=notrunc,fsync status=none
  printf '\x55\xaa' | dd of="$dev" bs=1 seek=510 count=2 conv=notrunc,fsync status=none
}

make_partition1() {
  local start="$1" type="$2"
  local sectors=262144
  printf 'label: dos\nunit: sectors\n\nstart=%s, size=%s, type=%s, bootable\n' "$start" "$sectors" "$type" | sfdisk --wipe always "$DISK" >/dev/null
  settle
  PART="$(lsblk -lnpo NAME,PARTN "$DISK" | awk '$2==1{print $1;exit}')"
  [[ -n "$PART" && -b "$PART" ]] || die "Partition #1 did not appear"
}

format_fs() {
  local dev="$1" fs="$2"
  case "$fs" in
    fat16) mkfs.fat -F 16 -n D640TEST "$dev" >/dev/null ;;
    fat32) mkfs.fat -F 32 -n D640TEST "$dev" >/dev/null ;;
    ntfs)  mkfs.ntfs -F -Q -L D640TEST "$dev" >/dev/null ;;
    *) die "Internal error: unknown filesystem $fs" ;;
  esac
  sync
}

setup_partitioned() {
  local start="$1" type="$2" fs="$3" tag="$4" mode="${5:-lba}"
  wipe_disk
  make_partition1 "$start" "$type"
  format_fs "$PART" "$fs"
  patch_pbr "$PART" "$fs" "$tag"
  compile_chain_mbr "$TMP/mbr.bin" "$tag" "$mode"
  write_mbr_code "$TMP/mbr.bin"
}

preflight_asm
confirm_erase

case "$CASE_ID" in
  mbr-direct)
    wipe_disk
    make_partition1 63 06
    format_fs "$PART" fat16
    compile_direct_mbr "$TMP/mbr.bin"
    write_mbr_code "$TMP/mbr.bin"
    ;;
  mbr-fat16-63)      setup_partitioned 63 06 fat16 FAT16-63-06 lba ;;
  mbr-fat16-63-chs)  setup_partitioned 63 06 fat16 FAT16-63-06 chs ;;
  mbr-fat16-lba63) setup_partitioned 63 0e fat16 FAT16-63-0E ;;
  mbr-fat32-63)      setup_partitioned 63 0b fat32 FAT32-63-0B lba ;;
  mbr-fat32-63-chs)  setup_partitioned 63 0b fat32 FAT32-63-0B chs ;;
  mbr-fat32-lba63) setup_partitioned 63 0c fat32 FAT32-63-0C ;;
  mbr-ntfs-63)       setup_partitioned 63 07 ntfs NTFS-63-07 lba ;;
  mbr-ntfs-63-chs)   setup_partitioned 63 07 ntfs NTFS-63-07 chs ;;
  mbr-fat16-2048)  setup_partitioned 2048 0e fat16 FAT16-2048 ;;
  mbr-fat32-2048)  setup_partitioned 2048 0c fat32 FAT32-2048 ;;
  mbr-ntfs-2048)   setup_partitioned 2048 07 ntfs  NTFS-2048 ;;
  usbzip-fat16|usbzip-fat32)
    wipe_disk
    if [[ "$CASE_ID" == usbzip-fat32 ]]; then
      mkdiskimage -4 -F "$DISK" 1024 64 32
      fs=fat32; tag=USBZIP-FAT32
    else
      mkdiskimage -4 "$DISK" 1024 64 32
      fs=fat16; tag=USBZIP-FAT16
    fi
    settle
    PART="$(lsblk -lnpo NAME,PARTN "$DISK" | awk '$2==4{print $1;exit}')"
    [[ -n "$PART" && -b "$PART" ]] || die "ZIP partition #4 did not appear"
    patch_pbr "$PART" "$fs" "$tag"
    compile_chain_mbr "$TMP/mbr.bin" "$tag" chs
    write_mbr_code "$TMP/mbr.bin"
    ;;
  superfloppy-fat32)
    wipe_disk
    mkfs.fat -F 32 -I -n D640TEST "$DISK" >/dev/null
    patch_pbr "$DISK" fat32 SUPER-FAT32
    ;;
  superfloppy-ntfs)
    wipe_disk
    mkfs.ntfs -F -Q -L D640TEST "$DISK" >/dev/null
    patch_pbr "$DISK" ntfs SUPER-NTFS
    ;;
esac

sync
settle
printf '\nPrepared case: %s on %s\n' "$CASE_ID" "$DISK"
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,PTTYPE,PARTTYPE,PARTFLAGS "$DISK" 2>/dev/null || lsblk "$DISK"
printf '\nBoot this USB on the D640 now.\n'
case "$CASE_ID" in
  mbr-direct)
    printf 'SUCCESS marker: D640 MBR DIRECT OK\n'
    ;;
  superfloppy-*)
    printf 'SUCCESS marker: D640 PBR ... OK\n'
    ;;
  *)
    printf 'Expected first: D640 MBR ...\nExpected second: D640 PBR ... OK\n'
    printf 'If only the first appears, BIOS executed our MBR but INT13/PBR handoff failed.\n'
    ;;
esac
printf 'A blinking cursor with no marker means the firmware did not reach this boot code or froze before executing it.\n'