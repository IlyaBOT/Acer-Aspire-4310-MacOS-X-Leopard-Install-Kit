#!/usr/bin/env bash
# Generic physical-hardware collector for legacy Hackintosh research.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
OUTPUT_ROOT="${1:-$ROOT_DIR/input/hardware}"
TARGET_TAG="${2:-hardware}"

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/collect_linux_hardware_v2.sh [output-directory] [target-tag]

Collects PCI/USB/DMI/ACPI/EDID/audio/network/storage/input data and attempts a
read-only PCI option-ROM dump for display controllers. The report may contain
serial numbers, MAC addresses and firmware identifiers; keep it private.
USAGE
}

[[ "${1:-}" != -h && "${1:-}" != --help ]] || { usage; exit 0; }
[[ "$(uname -s)" == Linux ]] || { echo "Linux only" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 ..." >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
capture() {
  local out="$1"; shift
  {
    printf '$'; printf ' %q' "$@"; printf '\n\n'
    "$@"
  } > "$REPORT/$out" 2>&1 || true
}

for required in dd od sha256sum tar lsblk lspci; do
  have "$required" || { echo "Missing required command: $required" >&2; exit 1; }
done

mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd -- "$OUTPUT_ROOT" && pwd -P)"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
REPORT="$OUTPUT_ROOT/${TARGET_TAG}-Linux-SysReport-$STAMP-$$"
ARCHIVE="$REPORT.tar.gz"
mkdir -p "$REPORT"/{acpi-raw,acpi-dsl,dmi-raw,edid-raw,vbios,pci-sysfs}

printf 'Collecting private hardware report into %s\n' "$REPORT"

capture uname.txt uname -a
capture os-release.txt sh -c 'cat /etc/os-release 2>/dev/null; printf "\nCMDLINE\n"; cat /proc/cmdline'
capture lscpu.txt lscpu
capture cpuinfo.txt cat /proc/cpuinfo
capture memory.txt cat /proc/meminfo
have dmidecode && capture dmi.txt dmidecode
have biosdecode && capture biosdecode.txt biosdecode
capture pci-nnk.txt lspci -nnk
capture pci-verbose.txt lspci -vvnn
capture pci-config-space.txt lspci -xxxxnn
capture pci-tree.txt lspci -tv
have lsusb && capture usb.txt lsusb
have lsusb && capture usb-tree.txt lsusb -tv
have lsusb && capture usb-verbose.txt lsusb -v
have usb-devices && capture usb-devices.txt usb-devices
have lshw && capture lshw.txt lshw -numeric
have inxi && capture inxi.txt inxi -Fxxxrz
capture interrupts.txt cat /proc/interrupts
capture iomem.txt cat /proc/iomem
capture ioports.txt cat /proc/ioports
capture modules.txt sh -c 'lsmod; printf "\nBUILTINS\n"; cat /lib/modules/$(uname -r)/modules.builtin 2>/dev/null || true'
capture dmesg.txt dmesg -T
have journalctl && capture journal-kernel.txt journalctl -b -k --no-pager
capture input-devices.txt cat /proc/bus/input/devices
have udevadm && capture input-udev.txt sh -c 'for d in /sys/class/input/input*; do echo "### $d"; udevadm info --query=property --path="$d" 2>&1; done'
capture serio.txt sh -c 'find -L /sys/bus/serio/devices -maxdepth 3 -type f -print -exec sed -n "1,120p" {} \; 2>/dev/null'

if have xrandr && [[ -n "${DISPLAY:-}" ]]; then
  capture xrandr.txt env DISPLAY="$DISPLAY" xrandr --verbose --props
fi
capture drm.txt sh -c 'find -L /sys/class/drm -maxdepth 3 -type f \( -name status -o -name enabled -o -name modes -o -name mode -o -name dpms -o -name connector_id \) -print -exec cat {} \; 2>/dev/null'
capture backlight.txt sh -c 'for d in /sys/class/backlight/*; do [ -d "$d" ] || continue; echo "### $d"; for f in actual_brightness brightness max_brightness type bl_power scale; do [ -r "$d/$f" ] && printf "%s=" "$f" && cat "$d/$f"; done; done'

if have aplay; then
  capture audio-devices.txt sh -c 'aplay -l; printf "\nPLAYBACK PCMS\n"; aplay -L; printf "\nCAPTURE\n"; arecord -l; printf "\nCARDS\n"; cat /proc/asound/cards /proc/asound/devices 2>/dev/null'
fi
capture audio-codecs.txt sh -c 'for f in /proc/asound/card*/codec#*; do [ -f "$f" ] || continue; echo "### $f"; cat "$f"; done'

if have ethtool; then
  capture network-drivers.txt sh -c 'for n in /sys/class/net/*; do i=${n##*/}; echo "### $i"; ethtool -i "$i" 2>&1; ethtool "$i" 2>&1; done'
fi
have iw && capture wireless.txt iw dev
have rfkill && capture rfkill.txt rfkill list
have lsblk && capture block.txt lsblk -e 7 -o NAME,PATH,TRAN,VENDOR,MODEL,SERIAL,REV,SIZE,TYPE,FSTYPE,ROTA,RO,PHY-SEC,LOG-SEC,PARTUUID
have blkid && capture blkid.txt blkid
have fdisk && capture fdisk.txt fdisk -l
have sensors && capture thermal.txt sensors
capture power-supply.txt sh -c 'for d in /sys/class/power_supply/*; do [ -d "$d" ] || continue; echo "### $d"; cat "$d/uevent" 2>/dev/null; done'
capture sleep-wake.txt sh -c 'printf "MEM_SLEEP\n"; cat /sys/power/mem_sleep 2>/dev/null; printf "\nACPI_WAKEUP\n"; cat /proc/acpi/wakeup 2>/dev/null'

for dev in /sys/bus/pci/devices/*; do
  [[ -d "$dev" ]] || continue
  bdf="${dev##*/}"
  mkdir -p "$REPORT/pci-sysfs/$bdf"
  for field in vendor device subsystem_vendor subsystem_device class revision irq; do
    [[ -r "$dev/$field" ]] && cat "$dev/$field" > "$REPORT/pci-sysfs/$bdf/$field.txt" 2>/dev/null || true
  done
  [[ -L "$dev/driver" ]] && readlink -f "$dev/driver" > "$REPORT/pci-sysfs/$bdf/driver.txt" 2>/dev/null || true
done

if [[ -d /sys/firmware/acpi/tables ]]; then
  for source in /sys/firmware/acpi/tables/*; do
    [[ -f "$source" ]] || continue
    dd if="$source" of="$REPORT/acpi-raw/${source##*/}" bs=1M status=none
  done
  if [[ -d /sys/firmware/acpi/tables/dynamic ]]; then
    mkdir -p "$REPORT/acpi-raw/dynamic"
    for source in /sys/firmware/acpi/tables/dynamic/*; do
      [[ -f "$source" ]] || continue
      dd if="$source" of="$REPORT/acpi-raw/dynamic/${source##*/}" bs=1M status=none
    done
  fi
fi

if have acpidump; then
  capture acpidump.txt acpidump
fi

: > "$REPORT/acpi-validation.txt"
while IFS= read -r table; do
  actual="$(stat -c %s "$table")"
  declared="$(od -An -tu4 -j4 -N4 "$table" | tr -d ' ')"
  signature="$(dd if="$table" bs=1 count=4 status=none 2>/dev/null || true)"
  if [[ "$signature" == FACS ]]; then checksum=n/a; else checksum="$(od -An -tu1 -v "$table" | awk '{for(i=1;i<=NF;i++)s+=$i} END{print s%256}')"; fi
  printf '%-18s actual=%-7s declared=%-7s checksum=%s\n' "${table#$REPORT/acpi-raw/}" "$actual" "$declared" "$checksum" >> "$REPORT/acpi-validation.txt"
done < <(find "$REPORT/acpi-raw" -type f -print | LC_ALL=C sort)

if have iasl; then
  cp "$REPORT/acpi-raw"/DSDT "$REPORT/acpi-dsl/DSDT.aml" 2>/dev/null || true
  n=0
  for ssdt in "$REPORT/acpi-raw"/SSDT*; do
    [[ -f "$ssdt" ]] || continue
    cp "$ssdt" "$REPORT/acpi-dsl/SSDT-$n.aml"
    n=$((n+1))
  done
  (cd "$REPORT/acpi-dsl" && for f in *.aml; do [[ -f "$f" ]] && iasl -d "$f" >> iasl.log 2>&1 || true; done)
fi

for source in /sys/firmware/dmi/tables/DMI /sys/firmware/dmi/tables/smbios_entry_point; do
  [[ -f "$source" ]] || continue
  dd if="$source" of="$REPORT/dmi-raw/${source##*/}" bs=1M status=none
done

for source in /sys/class/drm/*/edid; do
  [[ -r "$source" ]] || continue
  connector="$(basename "$(dirname "$source")")"
  dd if="$source" of="$REPORT/edid-raw/$connector.bin" bs=1M status=none
  if have edid-decode; then edid-decode "$source" > "$REPORT/edid-raw/$connector.txt" 2>&1 || true; fi
done

: > "$REPORT/vbios/RESULTS.txt"
for dev in /sys/bus/pci/devices/*; do
  [[ -r "$dev/class" ]] || continue
  class="$(cat "$dev/class")"
  [[ "$class" == 0x03* ]] || continue
  bdf="${dev##*/}"
  if [[ -e "$dev/rom" ]]; then
    if { echo 1 > "$dev/rom"; } 2>/dev/null; then
      if cat "$dev/rom" > "$REPORT/vbios/$bdf.rom" 2>/dev/null && [[ -s "$REPORT/vbios/$bdf.rom" ]]; then
        printf '%s OK bytes=%s sha256=%s\n' "$bdf" "$(stat -c %s "$REPORT/vbios/$bdf.rom")" "$(sha256sum "$REPORT/vbios/$bdf.rom" | awk '{print $1}')" >> "$REPORT/vbios/RESULTS.txt"
      else
        rm -f "$REPORT/vbios/$bdf.rom"
        printf '%s READ_FAILED\n' "$bdf" >> "$REPORT/vbios/RESULTS.txt"
      fi
      echo 0 > "$dev/rom" 2>/dev/null || true
    else
      printf '%s ENABLE_FAILED\n' "$bdf" >> "$REPORT/vbios/RESULTS.txt"
    fi
  else
    printf '%s NO_SYSFS_ROM\n' "$bdf" >> "$REPORT/vbios/RESULTS.txt"
  fi
done

if have decode-dimms; then
  capture spd.txt decode-dimms
fi

(
  cd "$REPORT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
tar -C "$OUTPUT_ROOT" -czf "$ARCHIVE" "$(basename "$REPORT")"
printf 'Archive: %s\nSHA-256: %s\n' "$ARCHIVE" "$(sha256sum "$ARCHIVE" | awk '{print $1}')"
printf 'Keep the report private; commit only sanitized facts.\n'
