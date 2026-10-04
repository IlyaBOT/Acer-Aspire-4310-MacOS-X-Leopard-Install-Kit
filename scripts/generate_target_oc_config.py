#!/usr/bin/env python3
"""Generate a narrow legacy OpenCore config for a declared hardware target.

This intentionally starts from the exact Sample.plist bundled with the selected
OpenCore release so new mandatory keys are inherited from that release.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import uuid
from pathlib import Path, PurePosixPath

KERNEL_RANGES = {
    "leopard": ("9.0.0", "9.99.99"),
    "snowleopard": ("10.0.0", "10.99.99"),
    "mavericks": ("13.0.0", "13.99.99"),
}

BOOT_ARGS = {
    "normal": "",
    "verbose": "-v keepsyms=1",
    "safe": "-v -x keepsyms=1 debug=0x100",
    "diagnostic": "-v keepsyms=1 debug=0x108 io=0x20007f",
}


def env_yes(name: str) -> bool:
    return os.environ.get(name, "").strip().upper() in {"1", "YES", "TRUE", "ON"}


def clear_samples(config: dict) -> None:
    config["ACPI"]["Add"] = []
    config["ACPI"]["Delete"] = []
    config["ACPI"]["Patch"] = []
    config["Booter"]["MmioWhitelist"] = []
    config["Booter"]["Patch"] = []
    config["DeviceProperties"]["Add"] = {}
    config["DeviceProperties"]["Delete"] = {}
    config["Kernel"]["Add"] = []
    config["Kernel"]["Block"] = []
    config["Kernel"]["Force"] = []
    config["Kernel"]["Patch"] = []
    config["Misc"]["BlessOverride"] = []
    config["Misc"]["Entries"] = []
    config["Misc"]["Tools"] = []
    config["UEFI"]["Drivers"] = []
    config["UEFI"]["ReservedMemory"] = []


def read_kext(oc_root: Path, bundle_path: str, minimum: str, maximum: str, arch: str) -> dict:
    relative = PurePosixPath(bundle_path)
    bundle = (oc_root / "Kexts").joinpath(*relative.parts)
    info_path = bundle / "Contents" / "Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    executable = info.get("CFBundleExecutable", "")
    executable_path = f"Contents/MacOS/{executable}" if executable else ""
    bundle_id = info.get("CFBundleIdentifier", "UNKNOWN")
    version = info.get("CFBundleVersion", "UNKNOWN")
    return {
        "Arch": arch,
        "BundlePath": str(relative),
        "Comment": f"{bundle_id} {version}; statically checked {arch} candidate",
        "Enabled": True,
        "ExecutablePath": executable_path,
        "MaxKernel": maximum,
        "MinKernel": minimum,
        "PlistPath": "Contents/Info.plist",
    }


def rom_bytes(text: str) -> bytes:
    raw = text.encode("ascii", "strict")
    if not 1 <= len(raw) <= 6:
        raise ValueError("--rom-ascii must contain 1..6 ASCII bytes")
    return raw.ljust(6, b"\x00")


def gpu_blacklist_properties() -> dict:
    """Return an early IOPCI match poison for a GPU exposed by firmware.

    This does not physically remove the PCI function. It prevents macOS graphics
    drivers from matching it by replacing its display identity/class properties
    before normal driver matching begins.
    """
    return {
        "name": "unused",
        "IOName": "#display",
        "class-code": b"\xff\xff\xff\xff",
        "vendor-id": b"\xff\xff\x00\x00",
        "device-id": b"\xff\xff\x00\x00",
    }


def load_kernel_patches(path: Path, amd_core_count: int | None) -> list[dict]:
    """Load a Kernel/Patch array and optionally specialize the Mavericks AMD core-count patch."""
    with path.open("rb") as handle:
        source = plistlib.load(handle)

    patches = source.get("Kernel", {}).get("Patch")
    if not isinstance(patches, list) or not patches:
        raise ValueError(f"{path} does not contain a non-empty Kernel/Patch array")

    normalized: list[dict] = []
    core_patch_indexes: list[int] = []
    for index, item in enumerate(patches):
        if not isinstance(item, dict):
            raise ValueError(f"{path}: Kernel/Patch[{index}] is not a dictionary")
        patch = dict(item)
        comment = str(patch.get("Comment", ""))
        if "cpuid_cores_per_package" in comment:
            core_patch_indexes.append(index)
        normalized.append(patch)

    if amd_core_count is not None:
        if not 1 <= amd_core_count <= 255:
            raise ValueError("--amd-core-count must be in range 1..255")
        if len(core_patch_indexes) != 1:
            raise ValueError(
                f"{path}: expected exactly one cpuid_cores_per_package patch, "
                f"found {len(core_patch_indexes)}"
            )
        patch = normalized[core_patch_indexes[0]]
        current = patch.get("Replace")
        expected = b"\xBA\x00\x00\x00\x00"
        if current != expected:
            raise ValueError(
                f"{path}: unexpected Mavericks cpuid_cores_per_package Replace value "
                f"{current!r}; expected {expected!r}"
            )
        patch["Replace"] = b"\xBA" + bytes([amd_core_count]) + b"\x00\x00\x00"

    return normalized


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--oc-root", required=True, type=Path)
    parser.add_argument("--os", required=True, choices=tuple(KERNEL_RANGES))
    parser.add_argument("--target-name", required=True)
    parser.add_argument("--smbios", required=True)
    parser.add_argument("--rom-ascii", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--mlb", required=True)
    parser.add_argument("--uuid-seed", required=True)
    parser.add_argument("--kernel-arch", default="i386", choices=("i386-user32", "i386", "x86_64"))
    parser.add_argument("--kernel-cache", default="Auto", choices=("Auto", "Cacheless", "Mkext", "Prelinked"))
    parser.add_argument("--boot-preset", default="diagnostic", choices=tuple(BOOT_ARGS))
    parser.add_argument("--runtime-profile", default="legacy", choices=("off", "legacy", "modern"))
    parser.add_argument("--custom-kernel", action="store_true", help="Enable OpenCore Kernel/Scheme/CustomKernel. The D640 default does not use this; its AMD mach_kernel is installed on the HFS+ volume instead.")
    parser.add_argument(
        "--legacy-commpage",
        dest="legacy_commpage",
        action="store_true",
        default=env_yes("TARGET_LEGACY_COMMPAGE"),
        help="Enable OpenCore LegacyCommpage. Defaults from TARGET_LEGACY_COMMPAGE.",
    )
    parser.add_argument("--no-legacy-commpage", dest="legacy_commpage", action="store_false")
    parser.add_argument(
        "--provide-current-cpu-info",
        dest="provide_current_cpu_info",
        action="store_true",
        default=env_yes("TARGET_PROVIDE_CURRENT_CPU_INFO"),
    )
    parser.add_argument("--no-provide-current-cpu-info", dest="provide_current_cpu_info", action="store_false")
    parser.add_argument(
        "--no-release-usb-ownership",
        dest="release_usb_ownership",
        action="store_false",
        default=True,
        help="Disable UEFI/Quirks/ReleaseUsbOwnership for firmware that does not require ownership takeover.",
    )
    parser.add_argument(
        "--setup-virtual-map",
        action="store_true",
        help="Enable Booter/Quirks/SetupVirtualMap for older UEFI firmware.",
    )
    parser.add_argument("--driver", action="append", default=[])
    parser.add_argument("--kext", action="append", default=[])
    parser.add_argument(
        "--blacklist-gpu-pci-path",
        action="append",
        default=[],
        help=(
            "Poison an exposed GPU's macOS IOPCI matching properties at this "
            "OpenCore PCI path (repeatable)."
        ),
    )
    parser.add_argument(
        "--kernel-patches-plist",
        type=Path,
        help="Import Kernel/Patch entries from an external plist.",
    )
    parser.add_argument(
        "--amd-core-count",
        type=int,
        help="Specialize the Mavericks AMD cpuid_cores_per_package patch for physical cores.",
    )
    parser.add_argument("--acpi", action="append", default=[])
    parser.add_argument("--extra-boot-arg", action="append", default=[])
    parser.add_argument("--drop-apic-oem-table-id")
    parser.add_argument("--drop-apic-table-length", type=int)
    parser.add_argument("--oc-version", default="UNKNOWN")
    args = parser.parse_args()

    minimum, maximum = KERNEL_RANGES[args.os]
    kext_arch = "i386" if args.kernel_arch == "i386-user32" else args.kernel_arch

    with args.sample.open("rb") as handle:
        config = plistlib.load(handle)
    clear_samples(config)

    booter = config["Booter"]["Quirks"]
    booter["FixupAppleEfiImages"] = True
    booter["SetupVirtualMap"] = args.setup_virtual_map
    if args.runtime_profile == "off":
        booter["EnableSafeModeSlide"] = False
        booter["EnableWriteUnprotector"] = False
        booter["ProvideCustomSlide"] = False
        booter["RebuildAppleMemoryMap"] = False
        booter["SyncRuntimePermissions"] = False
    elif args.runtime_profile == "legacy":
        booter["EnableSafeModeSlide"] = False
        booter["EnableWriteUnprotector"] = True
        booter["RebuildAppleMemoryMap"] = False
        booter["SyncRuntimePermissions"] = False
    else:
        booter["EnableWriteUnprotector"] = False
        booter["RebuildAppleMemoryMap"] = True
        booter["SyncRuntimePermissions"] = True

    config["ACPI"]["Add"] = [
        {"Comment": f"{args.target_name} user ACPI", "Enabled": True, "Path": path}
        for path in args.acpi
    ]
    if args.drop_apic_oem_table_id:
        if args.drop_apic_table_length is None:
            parser.error("--drop-apic-oem-table-id requires --drop-apic-table-length")
        oem = args.drop_apic_oem_table_id.encode("ascii", "strict")
        if len(oem) > 8:
            parser.error("APIC OEM table ID must be at most 8 ASCII bytes")
        config["ACPI"]["Delete"] = [{
            "All": False,
            "Comment": f"Drop target-specific duplicate MADT for {args.target_name}",
            "Enabled": True,
            "OemTableId": oem.ljust(8, b" "),
            "TableLength": args.drop_apic_table_length,
            "TableSignature": b"APIC",
        }]

    for pci_path in args.blacklist_gpu_pci_path:
        if not pci_path.startswith("PciRoot("):
            parser.error(
                f"--blacklist-gpu-pci-path must be an OpenCore PciRoot(...) path: {pci_path}"
            )
        config["DeviceProperties"]["Add"][pci_path] = gpu_blacklist_properties()

    config["Kernel"]["Add"] = [
        read_kext(args.oc_root, path, minimum, maximum, kext_arch) for path in args.kext
    ]
    if args.amd_core_count is not None and args.kernel_patches_plist is None:
        parser.error("--amd-core-count requires --kernel-patches-plist")
    if args.kernel_patches_plist is not None:
        try:
            config["Kernel"]["Patch"] = load_kernel_patches(
                args.kernel_patches_plist, args.amd_core_count
            )
        except (OSError, ValueError, plistlib.InvalidFileException) as exc:
            parser.error(str(exc))
    emulate = config["Kernel"]["Emulate"]
    emulate["Cpuid1Data"] = b""
    emulate["Cpuid1Mask"] = b""
    emulate["DummyPowerManagement"] = True
    emulate["MinKernel"] = minimum
    emulate["MaxKernel"] = maximum

    quirks = config["Kernel"]["Quirks"]
    quirks["AppleCpuPmCfgLock"] = False
    quirks["LegacyCommpage"] = args.legacy_commpage
    quirks["ProvideCurrentCpuInfo"] = args.provide_current_cpu_info

    scheme = config["Kernel"]["Scheme"]
    scheme["CustomKernel"] = args.custom_kernel
    scheme["FuzzyMatch"] = True
    scheme["KernelArch"] = args.kernel_arch
    scheme["KernelCache"] = args.kernel_cache

    boot = config["Misc"]["Boot"]
    boot["HideAuxiliary"] = False
    boot["PickerMode"] = "Builtin"
    boot["ShowPicker"] = True
    boot["TakeoffDelay"] = 10_000
    boot["Timeout"] = 10

    debug = config["Misc"]["Debug"]
    debug["AppleDebug"] = True
    debug["ApplePanic"] = True
    debug["DisableWatchDog"] = True
    debug["DisplayLevel"] = 0x80000042
    debug["SysReport"] = args.boot_preset == "diagnostic"
    debug["Target"] = 67

    security = config["Misc"]["Security"]
    security["AllowSetDefault"] = True
    security["DmgLoading"] = "Any"
    security["ScanPolicy"] = 0
    security["SecureBootModel"] = "Disabled"
    security["Vault"] = "Optional"

    boot_parts = [BOOT_ARGS[args.boot_preset]]
    if args.os == "snowleopard" and args.kernel_arch == "i386":
        boot_parts.append("arch=i386")
    boot_parts.extend(args.extra_boot_arg)
    boot_args = " ".join(x.strip() for x in boot_parts if x.strip())

    config["NVRAM"]["Add"] = {
        "4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14": {
            "DefaultBackgroundColor": b"\x00\x00\x00\x00"
        },
        "7C436110-AB2A-4BBB-A880-FE41995C9F82": {
            "boot-args": boot_args,
            "prev-lang:kbd": b"en-US:0",
            "run-efi-updater": "No",
        },
    }
    config["NVRAM"]["Delete"] = {
        "7C436110-AB2A-4BBB-A880-FE41995C9F82": ["boot-args"]
    }

    config["PlatformInfo"]["Automatic"] = True
    config["PlatformInfo"]["UpdateDataHub"] = True
    config["PlatformInfo"]["UpdateNVRAM"] = True
    config["PlatformInfo"]["UpdateSMBIOS"] = True
    config["PlatformInfo"]["UpdateSMBIOSMode"] = "Create"
    generic = config["PlatformInfo"]["Generic"]
    generic.update({
        "AdviseFeatures": False,
        "MLB": args.mlb,
        "MaxBIOSVersion": False,
        "ProcessorType": 0,
        "ROM": rom_bytes(args.rom_ascii),
        "SpoofVendor": True,
        "SystemMemoryStatus": "Auto",
        "SystemProductName": args.smbios,
        "SystemSerialNumber": args.serial,
        "SystemUUID": str(uuid.uuid5(uuid.NAMESPACE_DNS, args.uuid_seed)).upper(),
    })

    config["UEFI"]["Drivers"] = [{
        "Arguments": "",
        "Comment": f"{args.target_name} legacy boot driver",
        "Enabled": True,
        "LoadEarly": False,
        "Path": driver,
    } for driver in args.driver]
    input_config = config["UEFI"]["Input"]
    input_config["KeyForgetThreshold"] = 9
    input_config["KeySupport"] = True
    input_config["KeySupportMode"] = "V1"
    config["UEFI"]["Output"]["ProvideConsoleGop"] = True
    config["UEFI"]["Output"]["Resolution"] = "Max"
    config["UEFI"]["Quirks"]["ReleaseUsbOwnership"] = args.release_usb_ownership
    config["UEFI"]["Quirks"]["RequestBootVarRouting"] = False

    config["#Revision"] = (
        f"{args.target_name} profile generated from OpenCore {args.oc_version} Sample.plist; "
        f"{args.os}/{args.kernel_arch}"
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as handle:
        plistlib.dump(config, handle, fmt=plistlib.FMT_XML, sort_keys=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
