#!/usr/bin/env python3
from __future__ import print_function

import argparse
import datetime
import json
from pathlib import Path
import platform
import re
import shlex
import shutil
import socket
import subprocess
import sys

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
DEFAULT_PROFILES_DIR = ROOT_DIR / "profiles" / "generated"

PLACEHOLDERS = {
    "", "unknown", "none", "n/a", "not specified", "not applicable",
    "system product name", "system manufacturer", "to be filled by o.e.m.",
    "to be filled by oem", "default string", "defaultstring",
}

LAPTOP_CHASSIS_TYPES = {8, 9, 10, 14, 30, 31, 32}
PC_CHASSIS_TYPES = {
    3, 4, 5, 6, 7, 12, 13, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
    26, 27, 28, 29, 33, 34, 35, 36,
}


class Collector(object):
    def __init__(self):
        self.warnings = []
        self._warned = set()

    def warn(self, message):
        if message not in self._warned:
            self._warned.add(message)
            self.warnings.append(message)

    def read_text(self, path):
        try:
            value = Path(path).read_text(errors="replace").strip().replace("\x00", "")
        except (OSError, PermissionError):
            return None
        return value or None

    def run(self, argv, timeout=8):
        if not argv:
            return None
        exe = argv[0]
        if shutil.which(exe) is None:
            self.warn(
                "tool '%s' is not installed; related hardware fields will be omitted"
                % exe
            )
            return None
        try:
            cp = subprocess.run(
                list(argv),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                errors="replace",
                timeout=timeout,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            self.warn("could not run %s: %s" % (" ".join(argv), exc))
            return None
        if cp.returncode != 0:
            detail = (cp.stderr or "").strip().splitlines()
            suffix = ": %s" % detail[-1] if detail else ""
            self.warn(
                "%s returned status %s%s"
                % (" ".join(argv), cp.returncode, suffix)
            )
            return None
        out = (cp.stdout or "").strip()
        return out or None


def valid_text(value):
    if value is None:
        return None
    value = " ".join(value.strip().split())
    if value.lower() in PLACEHOLDERS:
        return None
    return value or None


def sanitize_slug(value):
    value = value.lower().strip()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    value = re.sub(r"-+", "-", value).strip("-")
    if not value:
        value = "generic-x86-profile"
    return value[:96].rstrip("-")


def arch_info(raw, collector):
    value = (raw or "").lower()
    if value in ("x86_64", "amd64"):
        return "AMD64", "x86_64", "X64"
    if value in ("i386", "i486", "i586", "i686", "x86"):
        return "i386", "i386", "IA32"
    collector.warn(
        "host architecture '%s' is not x86/i386/AMD64" % (raw or "unknown")
    )
    return raw or "unknown", raw or "unknown", "UNKNOWN"


def parse_cpuinfo(collector):
    raw = collector.read_text("/proc/cpuinfo")
    result = {}
    blocks = []

    if raw:
        for chunk in re.split(r"\n\s*\n", raw):
            row = {}
            for line in chunk.splitlines():
                if ":" not in line:
                    continue
                key, value = line.split(":", 1)
                row[key.strip().lower()] = value.strip()
            if row:
                blocks.append(row)

    if blocks:
        first = blocks[0]
        result["model_name"] = valid_text(
            first.get("model name")
            or first.get("hardware")
            or first.get("processor")
        )
        result["vendor"] = valid_text(first.get("vendor_id"))
        result["family"] = valid_text(first.get("cpu family"))
        result["model"] = valid_text(first.get("model"))
        result["stepping"] = valid_text(first.get("stepping"))

        flags_text = first.get("flags") or first.get("features") or ""
        result["flags"] = sorted(set(flags_text.split()))

        processors = [b for b in blocks if "processor" in b]
        if processors:
            result["threads"] = len(processors)

        physical_cores = {
            (b.get("physical id"), b.get("core id"))
            for b in processors
            if b.get("physical id") is not None
            and b.get("core id") is not None
        }
        if physical_cores:
            result["cores"] = len(physical_cores)
        else:
            try:
                cores_per_socket = int(first.get("cpu cores") or "0")
                sockets = (
                    len(
                        {
                            b.get("physical id")
                            for b in processors
                            if b.get("physical id") is not None
                        }
                    )
                    or 1
                )
                if cores_per_socket > 0:
                    result["cores"] = cores_per_socket * sockets
            except ValueError:
                pass

    lscpu = collector.run(["lscpu"])
    if lscpu:
        parsed = {}
        for line in lscpu.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                parsed[key.strip().lower()] = value.strip()
        result.setdefault("model_name", valid_text(parsed.get("model name")))
        result.setdefault("vendor", valid_text(parsed.get("vendor id")))
        result.setdefault("family", valid_text(parsed.get("cpu family")))
        result.setdefault("model", valid_text(parsed.get("model")))
        result.setdefault("stepping", valid_text(parsed.get("stepping")))
        if "threads" not in result:
            try:
                result["threads"] = int(parsed.get("cpu(s)", "0"))
            except ValueError:
                pass
        if "cores" not in result:
            try:
                result["cores"] = int(
                    parsed.get("core(s) per socket", "0")
                ) * int(parsed.get("socket(s)", "1"))
            except ValueError:
                pass

    if not result.get("model_name"):
        collector.warn(
            "CPU model name could not be read; using 'Unknown x86 CPU' fallback"
        )
        result["model_name"] = "Unknown x86 CPU"

    if not result.get("vendor"):
        collector.warn(
            "CPU vendor could not be read; vendor-specific compatibility is unknown"
        )

    flags = set(result.get("flags") or [])
    result["long_mode"] = "lm" in flags
    result["sse3"] = "pni" in flags or "sse3" in flags
    result["ssse3"] = "ssse3" in flags
    result["sse4a"] = "sse4a" in flags
    result["sse41"] = "sse4_1" in flags
    result["sse42"] = "sse4_2" in flags
    result["avx"] = "avx" in flags
    return result


def dmi_value(collector, name):
    return valid_text(collector.read_text(Path("/sys/class/dmi/id") / name))


def detect_form_factor(collector):
    raw = collector.read_text("/sys/class/dmi/id/chassis_type")
    chassis = None

    if raw:
        try:
            chassis = int(raw.strip())
        except ValueError:
            collector.warn("DMI chassis_type '%s' is malformed" % raw)

    if chassis in LAPTOP_CHASSIS_TYPES:
        return "Laptop", chassis, "DMI chassis_type"
    if chassis in PC_CHASSIS_TYPES:
        return "PC", chassis, "DMI chassis_type"

    batteries = list(Path("/sys/class/power_supply").glob("BAT*"))
    if batteries:
        collector.warn(
            "DMI chassis type is missing/unknown; inferred Laptop from BAT* power supply"
        )
        return "Laptop", chassis, "battery fallback"

    collector.warn(
        "DMI chassis type is missing/unknown and no battery was detected; "
        "defaulting form factor to PC"
    )
    return "PC", chassis, "standard fallback"


def join_values(values):
    cleaned = [
        " ".join(str(value).split())
        for value in values
        if value and str(value).strip()
    ]
    return " | ".join(cleaned) if cleaned else None


def collect_pci(collector):
    output = collector.run(["lspci", "-nn"])
    categories = {
        key: []
        for key in (
            "gpu",
            "audio",
            "ethernet",
            "wifi",
            "storage",
            "usb",
            "chipset",
        )
    }

    if not output:
        collector.warn(
            "PCI inventory unavailable; GPU/network/audio/storage PCI fields are omitted"
        )
        return [], {key: None for key in categories}

    lines = [line.strip() for line in output.splitlines() if line.strip()]

    for line in lines:
        low = line.lower()

        if any(
            token in low
            for token in (
                "vga compatible controller",
                "3d controller",
                "display controller",
            )
        ):
            categories["gpu"].append(line)

        if "audio device" in low or "multimedia audio controller" in low:
            categories["audio"].append(line)

        if "ethernet controller" in low:
            categories["ethernet"].append(line)

        if "network controller" in low or "wireless" in low:
            categories["wifi"].append(line)

        if any(
            token in low
            for token in (
                "sata controller",
                "raid bus controller",
                "ide interface",
                "non-volatile memory controller",
                "scsi storage controller",
            )
        ):
            categories["storage"].append(line)

        if "usb controller" in low:
            categories["usb"].append(line)

        if any(
            token in low
            for token in ("host bridge", "isa bridge", "smbus")
        ):
            categories["chipset"].append(line)

    return lines, {
        key: join_values(value) for key, value in categories.items()
    }


def collect_usb(collector):
    output = collector.run(["lsusb"])
    if not output:
        return []
    return [line.strip() for line in output.splitlines() if line.strip()]


def collect_storage(collector):
    output = collector.run(
        ["lsblk", "-dn", "-o", "NAME,TRAN,VENDOR,MODEL,SIZE,TYPE"]
    )
    if not output:
        return []

    rows = []
    for line in output.splitlines():
        line = " ".join(line.split())
        if not line:
            continue
        if line.lower().endswith(" disk") or " disk " in (
            " " + line.lower() + " "
        ):
            rows.append(line)
    return rows


def collect_input_names(collector):
    raw = collector.read_text("/proc/bus/input/devices")
    if not raw:
        return []

    names = []
    seen = set()
    for line in raw.splitlines():
        match = re.match(r'N:\s+Name="(.*)"', line.strip())
        if not match:
            continue
        name = valid_text(match.group(1))
        if name and name not in seen:
            seen.add(name)
            names.append(name)
    return names[:24]


def collect_display(collector):
    drm = Path("/sys/class/drm")
    if not drm.exists():
        return None

    found = []
    for status in drm.glob("*/status"):
        try:
            state = status.read_text().strip()
        except OSError:
            continue

        if state != "connected":
            continue

        connector = status.parent.name
        mode = None
        modes = status.parent / "modes"
        try:
            for line in modes.read_text().splitlines():
                if line.strip():
                    mode = line.strip()
                    break
        except OSError:
            pass

        found.append("%s %s" % (connector, mode or "connected"))

    return join_values(found)


def collect_battery(collector):
    rows = []
    for battery in sorted(Path("/sys/class/power_supply").glob("BAT*")):
        parts = [battery.name]
        for field in ("manufacturer", "model_name", "technology"):
            value = valid_text(collector.read_text(battery / field))
            if value:
                parts.append(value)
        rows.append(" ".join(parts))
    return join_values(rows)


def memory_description(collector):
    raw = collector.read_text("/proc/meminfo")
    if not raw:
        return None

    match = re.search(r"^MemTotal:\s+(\d+)\s+kB", raw, re.M)
    if not match:
        collector.warn("/proc/meminfo exists but MemTotal could not be parsed")
        return None

    kib = int(match.group(1))
    gib = kib / 1024.0 / 1024.0
    if gib >= 1:
        return "%.2f GiB" % gib
    return "%.0f MiB" % (kib / 1024.0)


def yesno(value):
    return "YES" if value else "NO"


def collect_hardware(target_os=None):
    collector = Collector()

    os_name = platform.system() or "unknown"
    raw_arch = platform.machine() or "unknown"
    arch_label, kernel_arch, oc_arch = arch_info(raw_arch, collector)

    if arch_label not in ("AMD64", "i386"):
        raise RuntimeError(
            "universal x86 profile requires x86/i386/AMD64; detected %r"
            % raw_arch
        )

    hostname = valid_text(socket.gethostname()) or "unknown-host"
    if hostname == "unknown-host":
        collector.warn(
            "OS hostname could not be read; using unknown-host fallback"
        )

    cpu = parse_cpuinfo(collector)
    form_factor, chassis_type, form_factor_source = detect_form_factor(
        collector
    )

    sys_vendor = dmi_value(collector, "sys_vendor")
    product_name = dmi_value(collector, "product_name")
    product_version = dmi_value(collector, "product_version")
    board_vendor = dmi_value(collector, "board_vendor")
    board_name = dmi_value(collector, "board_name")
    bios_vendor = dmi_value(collector, "bios_vendor")
    bios_version = dmi_value(collector, "bios_version")
    bios_date = dmi_value(collector, "bios_date")

    if not Path("/sys/class/dmi/id").exists():
        collector.warn(
            "DMI sysfs is unavailable; system/board/firmware identity is incomplete"
        )

    fallback_model = "Generic x86 %s" % form_factor
    model = product_name
    if not model:
        collector.warn(
            "DMI product name is missing/generic; using '%s' fallback"
            % fallback_model
        )
        model = fallback_model

    pci_lines, pci = collect_pci(collector)
    usb_lines = collect_usb(collector)
    storage_rows = collect_storage(collector)
    input_names = collect_input_names(collector)
    display = collect_display(collector)
    battery = collect_battery(collector)
    ram = memory_description(collector)

    firmware_mode = (
        "UEFI" if Path("/sys/firmware/efi").exists() else "legacy BIOS/CSM"
    )
    firmware_parts = [
        value
        for value in (bios_vendor, bios_version, bios_date, firmware_mode)
        if value
    ]
    firmware = (
        " ".join(firmware_parts) if firmware_parts else firmware_mode
    )

    cpu_vendor = str(cpu.get("vendor") or "")
    cpu_name = str(cpu.get("model_name") or "")
    if "AuthenticAMD" in cpu_vendor or cpu_name.upper().startswith("AMD "):
        collector.warn(
            "AMD CPU detected; this inventory does not imply vanilla XNU "
            "compatibility. Validate an AMD kernel/patch path separately for "
            "the requested macOS version."
        )

    target_os = target_os.strip().lower() if target_os else None

    fields = {
        "PROFILE_AUTOGENERATED": "YES",
        "PROFILE_ANALYSIS_ONLY": "YES",
        "PROFILE_SOURCE_OS": os_name,
        "PROFILE_HOSTNAME": hostname,
        "TARGET_MODEL": model,
        "TARGET_FORM_FACTOR": form_factor,
        "TARGET_ARCH": arch_label,
        "TARGET_KERNEL_ARCH_HINT": kernel_arch,
        "TARGET_OPENCORE_ARCH_HINT": oc_arch,
        "TARGET_CPU": str(cpu["model_name"]),
        "TARGET_FIRMWARE": firmware,
    }

    optional_fields = {
        "TARGET_VENDOR": sys_vendor,
        "TARGET_PRODUCT_VERSION": product_version,
        "TARGET_BOARD": join_values(
            [value for value in (board_vendor, board_name) if value]
        ),
        "TARGET_CPU_VENDOR": cpu.get("vendor"),
        "TARGET_CPU_FAMILY": cpu.get("family"),
        "TARGET_CPU_MODEL_NUMBER": cpu.get("model"),
        "TARGET_CPU_STEPPING": cpu.get("stepping"),
        "TARGET_CPU_CORES": cpu.get("cores"),
        "TARGET_CPU_THREADS": cpu.get("threads"),
        "TARGET_RAM": ram,
        "TARGET_CHIPSET": pci.get("chipset"),
        "TARGET_GPU": pci.get("gpu"),
        "TARGET_DISPLAY": display,
        "TARGET_AUDIO": pci.get("audio"),
        "TARGET_ETHERNET": pci.get("ethernet"),
        "TARGET_WIFI": pci.get("wifi"),
        "TARGET_STORAGE_CONTROLLERS": pci.get("storage"),
        "TARGET_STORAGE": join_values(storage_rows),
        "TARGET_USB_CONTROLLERS": pci.get("usb"),
        "TARGET_USB_DEVICES": join_values(usb_lines),
        "TARGET_INPUT": join_values(input_names),
        "TARGET_BATTERY": battery,
        "TARGET_REQUESTED_OS_PROFILE": target_os,
    }

    for key, value in optional_fields.items():
        if value is not None and str(value).strip():
            fields[key] = str(value)

    fields.update(
        {
            "TARGET_CPU_SUPPORTS_LONG_MODE": yesno(
                bool(cpu.get("long_mode"))
            ),
            "TARGET_CPU_SUPPORTS_SSE3": yesno(bool(cpu.get("sse3"))),
            "TARGET_CPU_SUPPORTS_SSSE3": yesno(bool(cpu.get("ssse3"))),
            "TARGET_CPU_SUPPORTS_SSE4A": yesno(bool(cpu.get("sse4a"))),
            "TARGET_CPU_SUPPORTS_SSE41": yesno(bool(cpu.get("sse41"))),
            "TARGET_CPU_SUPPORTS_SSE42": yesno(bool(cpu.get("sse42"))),
            "TARGET_CPU_SUPPORTS_AVX": yesno(bool(cpu.get("avx"))),
        }
    )

    details = {
        "source_os": os_name,
        "hostname": hostname,
        "raw_architecture": raw_arch,
        "architecture": arch_label,
        "kernel_arch_hint": kernel_arch,
        "opencore_arch_hint": oc_arch,
        "form_factor": form_factor,
        "form_factor_source": form_factor_source,
        "dmi_chassis_type": chassis_type,
        "cpu": cpu,
        "dmi": {
            "sys_vendor": sys_vendor,
            "product_name": product_name,
            "product_version": product_version,
            "board_vendor": board_vendor,
            "board_name": board_name,
            "bios_vendor": bios_vendor,
            "bios_version": bios_version,
            "bios_date": bios_date,
        },
        "pci_devices": pci_lines,
        "usb_devices": usb_lines,
        "storage_devices": storage_rows,
        "input_devices": input_names,
        "requested_os_profile": target_os,
        "warnings": collector.warnings,
    }

    return fields, details, collector.warnings


def print_report(fields, details, warnings):
    print("Universal x86/x86_64 hardware analysis")
    print()
    print("Host OS: %s" % fields.get("PROFILE_SOURCE_OS", "unknown"))
    print(
        "OS hostname: %s"
        % fields.get("PROFILE_HOSTNAME", "unknown-host")
    )
    print(
        "System: %s"
        % (
            " ".join(
                value
                for value in (
                    fields.get("TARGET_VENDOR"),
                    fields.get("TARGET_MODEL"),
                )
                if value
            )
        )
    )
    print(
        "Form factor: %s"
        % fields.get("TARGET_FORM_FACTOR", "PC")
    )
    print("Architecture: %s" % fields.get("TARGET_ARCH", "unknown"))
    print(
        "CPU: %s"
        % fields.get("TARGET_CPU", "Unknown x86 CPU")
    )

    if fields.get("TARGET_CPU_VENDOR"):
        print("CPU vendor: %s" % fields["TARGET_CPU_VENDOR"])

    if fields.get("TARGET_CPU_CORES") or fields.get(
        "TARGET_CPU_THREADS"
    ):
        print(
            "CPU topology: %s cores / %s threads"
            % (
                fields.get("TARGET_CPU_CORES", "?"),
                fields.get("TARGET_CPU_THREADS", "?"),
            )
        )

    if fields.get("TARGET_RAM"):
        print("Memory: %s" % fields["TARGET_RAM"])

    if fields.get("TARGET_FIRMWARE"):
        print("Firmware: %s" % fields["TARGET_FIRMWARE"])

    if fields.get("TARGET_REQUESTED_OS_PROFILE"):
        print(
            "Requested macOS profile: %s"
            % fields["TARGET_REQUESTED_OS_PROFILE"]
        )

    print()
    print("Detected devices:")

    rows = [
        ("Chipset", "TARGET_CHIPSET"),
        ("GPU", "TARGET_GPU"),
        ("Display", "TARGET_DISPLAY"),
        ("Audio", "TARGET_AUDIO"),
        ("Ethernet", "TARGET_ETHERNET"),
        ("Wi-Fi/Network", "TARGET_WIFI"),
        ("Storage controllers", "TARGET_STORAGE_CONTROLLERS"),
        ("Storage", "TARGET_STORAGE"),
        ("USB controllers", "TARGET_USB_CONTROLLERS"),
        ("Battery", "TARGET_BATTERY"),
        ("Input", "TARGET_INPUT"),
    ]

    any_devices = False
    for label, key in rows:
        value = fields.get(key)
        if value:
            any_devices = True
            print("  OK      %s: %s" % (label, value))

    if not any_devices:
        print("  WARN    no peripheral inventory was available")

    print()
    print("CPU feature hints:")

    for label, key in (
        ("Long mode", "TARGET_CPU_SUPPORTS_LONG_MODE"),
        ("SSE3", "TARGET_CPU_SUPPORTS_SSE3"),
        ("SSSE3", "TARGET_CPU_SUPPORTS_SSSE3"),
        ("SSE4.1", "TARGET_CPU_SUPPORTS_SSE41"),
        ("SSE4.2", "TARGET_CPU_SUPPORTS_SSE42"),
        ("SSE4a", "TARGET_CPU_SUPPORTS_SSE4A"),
        ("AVX", "TARGET_CPU_SUPPORTS_AVX"),
    ):
        print("  %-10s %s" % (label, fields.get(key, "UNKNOWN")))

    print()

    if warnings:
        print("Warnings:")
        for message in warnings:
            print("  WARN    %s" % message)
    else:
        print("Warnings: none")

    print()
    print(
        "Analysis only: no SMBIOS, kernel, kext, ACPI or macOS "
        "compatibility decision is inferred automatically from this inventory."
    )


def suggested_profile_name(fields):
    return "%s + %s + %s + %s" % (
        fields.get("PROFILE_HOSTNAME") or "unknown-host",
        fields.get("TARGET_CPU") or "Unknown x86 CPU",
        fields.get("TARGET_ARCH") or "AMD64",
        fields.get("TARGET_FORM_FACTOR") or "PC",
    )


def write_shell_conf(path, fields):
    lines = [
        "# Autogenerated local hardware-analysis profile.",
        "# Review detected values before using them for macOS work.",
        "# No SMBIOS/kernel/kext/ACPI choices are implied by this file.",
        "",
    ]

    for key in sorted(fields):
        lines.append(
            "%s=%s" % (key, shlex.quote(str(fields[key])))
        )

    lines.append("")
    path.write_text("\n".join(lines))


def save_profile(
    profiles_dir,
    display_name,
    fields,
    details,
    warnings,
):
    slug = sanitize_slug(display_name)
    directory = profiles_dir / slug

    if directory.exists():
        raise RuntimeError(
            "profile directory already exists: %s; "
            "choose a different --name" % directory
        )

    directory.mkdir(parents=True)

    now = (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
    )

    fields = dict(fields)
    fields["PROFILE_DISPLAY_NAME"] = display_name
    fields["PROFILE_SLUG"] = slug
    fields["PROFILE_CREATED_UTC"] = now

    write_shell_conf(directory / "hardware.conf", fields)

    profile_conf = {
        "PROFILE_NAME": display_name,
        "PROFILE_SLUG": slug,
        "PROFILE_STATUS": "analysis",
        "PROFILE_KIND": "hardware-analysis",
        "PROFILE_ARCH": fields.get("TARGET_ARCH", "unknown"),
        "PROFILE_FORM_FACTOR": fields.get(
            "TARGET_FORM_FACTOR", "PC"
        ),
        "PROFILE_CREATED_UTC": now,
    }

    if fields.get("TARGET_REQUESTED_OS_PROFILE"):
        profile_conf["PROFILE_REQUESTED_OS"] = fields[
            "TARGET_REQUESTED_OS_PROFILE"
        ]

    write_shell_conf(directory / "profile.conf", profile_conf)

    payload = dict(details)
    payload.update(
        {
            "profile_display_name": display_name,
            "profile_slug": slug,
            "created_utc": now,
            "hardware_fields": fields,
            "warnings": warnings,
        }
    )

    (directory / "profile.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n"
    )

    return directory


def show_profile(profiles_dir, slug):
    directory = profiles_dir / sanitize_slug(slug)
    json_path = directory / "profile.json"

    if not json_path.is_file():
        print(
            "ERROR: generated profile not found: %s" % slug,
            file=sys.stderr,
        )
        return 1

    payload = json.loads(json_path.read_text())
    fields = payload.get("hardware_fields") or {}
    warnings = payload.get("warnings") or []

    print(
        "Saved hardware-analysis profile: %s"
        % payload.get("profile_display_name", slug)
    )
    print(
        "Profile slug: %s"
        % payload.get("profile_slug", slug)
    )
    print("Profile path: %s" % directory)
    print()

    print_report(fields, payload, warnings)
    return 0


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description=(
            "Detect a generic x86/x86_64 PC and create an "
            "analysis-only hardware profile."
        )
    )

    parser.add_argument(
        "--mode",
        choices=("new", "universal"),
        default="new",
    )
    parser.add_argument(
        "--show",
        metavar="SLUG",
        help="show a previously generated local profile",
    )
    parser.add_argument(
        "--target-os",
        metavar="PROFILE",
        help="record the requested macOS profile name",
    )
    parser.add_argument(
        "--name",
        metavar="NAME",
        help="profile display name; skips the prompt",
    )
    parser.add_argument(
        "--profiles-dir",
        default=str(DEFAULT_PROFILES_DIR),
    )
    parser.add_argument("--non-interactive", action="store_true")
    parser.add_argument(
        "--doctor",
        action="store_true",
        help=(
            "compatibility alias; generic hardware analysis "
            "is always read-only"
        ),
    )

    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    profiles_dir = (
        Path(args.profiles_dir).expanduser().resolve()
    )

    if args.show:
        return show_profile(profiles_dir, args.show)

    try:
        fields, details, warnings = collect_hardware(
            args.target_os
        )
    except RuntimeError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 2

    print_report(fields, details, warnings)

    suggestion = suggested_profile_name(fields)
    print()
    print("Suggested profile name: %s" % suggestion)

    if args.mode == "universal":
        print(
            "Universal mode does not save a profile. "
            "Use --profile new to save this inventory."
        )
        return 0

    if args.name:
        display_name = args.name.strip()
    elif args.non_interactive or not sys.stdin.isatty():
        display_name = suggestion
        print(
            "Non-interactive input: accepting the suggested "
            "profile name."
        )
    else:
        try:
            entered = input(
                "Profile name [%s]: " % suggestion
            ).strip()
        except EOFError:
            entered = ""
        display_name = entered or suggestion

    try:
        directory = save_profile(
            profiles_dir,
            display_name or suggestion,
            fields,
            details,
            warnings,
        )
    except (OSError, RuntimeError) as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1

    print()
    print("Saved analysis profile: %s" % directory)
    print("  hardware: %s" % (directory / "hardware.conf"))
    print("  metadata: %s" % (directory / "profile.conf"))
    print("  JSON:     %s" % (directory / "profile.json"))
    print()
    print(
        "Generated profiles are local/private by default because "
        "hostnames and hardware inventory may identify a machine. "
        "Review before committing."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
