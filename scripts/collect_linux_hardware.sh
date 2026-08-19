#!/usr/bin/env bash
# Variables in single-quoted sh -c payloads expand in the child shell by design.
# shellcheck disable=SC2016
set -Eeuo pipefail

umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

usage() {
  cat <<'EOF'
Usage: ./scripts/collect_linux_hardware.sh [output-directory]

Collect a private Linux hardware/firmware report for the physical Aspire 4310.
The default output directory is input/hardware, which is ignored by Git.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
(( $# <= 1 )) || { usage >&2; exit 2; }
[[ "$(uname -s)" == "Linux" ]] || die "This collector must run on Linux."
for required in sudo dd od sha256sum tar; do
  have_cmd "$required" || die "Required command is missing: $required"
done

output_root="${1:-$ROOT_DIR/input/hardware}"
mkdir -p "$output_root"
output_root="$(cd -- "$output_root" && pwd -P)"
stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
report_dir="$output_root/Aspire4310-Linux-SysReport-$stamp-$$"
archive="$report_dir.tar.gz"
mkdir -p "$report_dir"

printf 'The report may contain DMI serials, disk identifiers, MAC addresses and firmware data.\n'
printf 'It must remain outside Git. Authenticating sudo for read-only hardware access...\n'
sudo -v

capture() {
  local output="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } >"$report_dir/$output" 2>&1 || true
}

capture uname.txt uname -a
capture os-release.txt sh -c 'cat /etc/os-release; printf "\nCMDLINE\n"; cat /proc/cmdline'
capture lscpu.txt lscpu
capture cpuinfo.txt cat /proc/cpuinfo
capture memory.txt cat /proc/meminfo
have_cmd dmidecode && capture dmi.txt sudo dmidecode
have_cmd biosdecode && capture biosdecode.txt sudo biosdecode
have_cmd lspci && capture pci-nnk.txt lspci -nnk
have_cmd lspci && capture pci-verbose.txt sudo lspci -vvnn
have_cmd lspci && capture pci-config-space.txt sudo lspci -xxxxnn
have_cmd lsusb && capture usb.txt lsusb
have_cmd lsusb && capture usb-tree.txt lsusb -tv
have_cmd lsusb && capture usb-verbose.txt sudo lsusb -v
have_cmd usb-devices && capture usb-devices.txt usb-devices
have_cmd lshw && capture lshw.txt sudo lshw -numeric
have_cmd inxi && capture inxi.txt inxi -Fxxxrz
capture interrupts.txt cat /proc/interrupts
capture iomem.txt sudo cat /proc/iomem
capture ioports.txt sudo cat /proc/ioports
capture modules.txt sh -c 'lsmod; printf "\nBUILTINS\n"; cat /lib/modules/$(uname -r)/modules.builtin 2>/dev/null || true'
capture dmesg.txt sudo dmesg -T
have_cmd journalctl && capture journal-kernel.txt sudo journalctl -b -k --no-pager
capture input-devices.txt cat /proc/bus/input/devices
have_cmd udevadm && capture input-udev.txt sh -c 'for d in /sys/class/input/input*; do echo "### $d"; udevadm info --query=property --path="$d" 2>&1; done'
capture serio.txt sh -c 'find -L /sys/bus/serio/devices -maxdepth 3 -type f -print -exec sed -n "1,80p" {} \; 2>/dev/null'
if have_cmd xinput; then
  capture xinput.txt env DISPLAY="${DISPLAY:-:0}" xinput list --long
fi
if have_cmd xrandr; then
  capture xrandr.txt env DISPLAY="${DISPLAY:-:0}" xrandr --verbose --props
fi
capture drm.txt sh -c 'find -L /sys/class/drm -maxdepth 3 -type f \( -name status -o -name enabled -o -name modes -o -name mode -o -name dpms -o -name connector_id \) -print -exec cat {} \; 2>/dev/null'
capture backlight.txt sh -c 'for d in /sys/class/backlight/*; do [ -d "$d" ] || continue; echo "### $d"; for f in actual_brightness brightness max_brightness type bl_power scale; do [ -r "$d/$f" ] && printf "%s=" "$f" && cat "$d/$f"; done; done'
if have_cmd aplay; then
  capture audio-devices.txt sh -c 'aplay -l; printf "\nPLAYBACK PCMS\n"; aplay -L; printf "\nCAPTURE\n"; arecord -l; printf "\nCARDS\n"; cat /proc/asound/cards /proc/asound/devices 2>/dev/null'
fi
capture audio-codecs.txt sh -c 'for f in /proc/asound/card*/codec#*; do [ -f "$f" ] || continue; echo "### $f"; cat "$f"; done'
if have_cmd ethtool; then
  capture network-drivers.txt sh -c 'for n in /sys/class/net/*; do i=${n##*/}; echo "### $i"; ethtool -i "$i" 2>&1; done'
fi
have_cmd rfkill && capture rfkill.txt sudo rfkill list
have_cmd lsblk && capture block.txt lsblk -e 7 -o NAME,PATH,TRAN,VENDOR,MODEL,REV,SIZE,TYPE,FSTYPE,ROTA,RO,PHY-SEC,LOG-SEC
capture power-supply.txt sh -c 'for d in /sys/class/power_supply/*; do [ -d "$d" ] || continue; echo "### $d"; cat "$d/uevent" 2>/dev/null; done'
capture sleep-wake.txt sh -c 'printf "MEM_SLEEP\n"; cat /sys/power/mem_sleep 2>/dev/null; printf "\nACPI_WAKEUP\n"; cat /proc/acpi/wakeup 2>/dev/null'
have_cmd sensors && capture thermal.txt sensors
capture acer-wmi.txt sh -c 'find -L /sys/devices/platform/acer-wmi -maxdepth 3 -type f -print -exec sed -n "1,80p" {} \; 2>/dev/null'

acpi_dir="$report_dir/acpi-raw"
mkdir -p "$acpi_dir/dynamic"
if [[ -d /sys/firmware/acpi/tables ]]; then
  for source in /sys/firmware/acpi/tables/*; do
    [[ -f "$source" ]] || continue
    sudo dd if="$source" of="$acpi_dir/${source##*/}" bs=1M status=none
  done
  for source in /sys/firmware/acpi/tables/dynamic/*; do
    [[ -f "$source" ]] || continue
    sudo dd if="$source" of="$acpi_dir/dynamic/${source##*/}" bs=1M status=none
  done
fi

dmi_dir="$report_dir/dmi-raw"
mkdir -p "$dmi_dir"
for source in /sys/firmware/dmi/tables/DMI /sys/firmware/dmi/tables/smbios_entry_point; do
  [[ -f "$source" ]] || continue
  sudo dd if="$source" of="$dmi_dir/${source##*/}" bs=1M status=none
done

edid_dir="$report_dir/edid-raw"
mkdir -p "$edid_dir"
for source in /sys/class/drm/*/edid; do
  [[ -r "$source" ]] || continue
  connector="$(basename "$(dirname "$source")")"
  dd if="$source" of="$edid_dir/$connector.bin" bs=1M status=none
done

sudo chown -R "$(id -u):$(id -g)" "$report_dir"

: >"$report_dir/acpi-validation.txt"
for table in "$acpi_dir"/* "$acpi_dir"/dynamic/*; do
  [[ -f "$table" ]] || continue
  actual="$(stat -c %s "$table")"
  declared="$(od -An -tu4 -j4 -N4 "$table" | tr -d ' ')"
  signature="$(dd if="$table" bs=1 count=4 status=none 2>/dev/null || true)"
  if [[ "$signature" == "FACS" ]]; then
    checksum="n/a"
  else
    checksum="$(od -An -tu1 -v "$table" | awk '{for (i=1; i<=NF; i++) sum+=$i} END {print sum%256}')"
  fi
  printf '%-12s actual=%-6s declared=%-6s checksum=%s %s\n' \
    "${table##*/}" "$actual" "$declared" "$checksum" \
    "$( [[ "$actual" == "$declared" && "$checksum" =~ ^(0|n/a)$ ]] && printf OK || printf MISMATCH )" \
    >>"$report_dir/acpi-validation.txt"
done

: >"$report_dir/edid-validation.txt"
for edid in "$edid_dir"/*.bin; do
  [[ -f "$edid" ]] || continue
  bytes="$(stat -c %s "$edid")"
  checksum="$(od -An -tu1 -v "$edid" | awk '{for (i=1; i<=NF; i++) sum+=$i} END {print sum%256}')"
  printf '%-24s bytes=%-4s checksum=%s sha256=' "${edid##*/}" "$bytes" "$checksum" \
    >>"$report_dir/edid-validation.txt"
  sha256sum "$edid" | awk '{print $1}' >>"$report_dir/edid-validation.txt"
done

checksum_tmp="$output_root/.Aspire4310-SHA256SUMS.$$"
(
  cd "$report_dir"
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) >"$checksum_tmp"
mv -- "$checksum_tmp" "$report_dir/SHA256SUMS"
tar -C "$output_root" -czf "$archive" "$(basename "$report_dir")"

printf 'Report:  %s\n' "$report_dir"
printf 'Archive: %s\n' "$archive"
printf 'SHA-256: '
sha256sum "$archive" | awk '{print $1}'
printf 'Keep the report private; commit only sanitized facts.\n'
