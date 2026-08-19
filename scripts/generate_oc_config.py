#!/usr/bin/env python3
"""Generate a narrow Aspire 4310 OpenCore config from the matching Sample.plist."""

from __future__ import annotations

import argparse
import plistlib
import uuid
from pathlib import Path, PurePosixPath


KERNEL_RANGES = {
    "leopard": ("9.0.0", "9.99.99"),
    "snowleopard": ("10.0.0", "10.99.99"),
}

BOOT_ARGS = {
    "normal": "",
    "verbose": "-v keepsyms=1",
    "safe": "-v -x keepsyms=1 debug=0x100",
    # DB_LOG_PI_SCRN (0x100) keeps panic output visible; DB_KPRT (0x8)
    # exposes the otherwise hidden early XNU kprintf path on the console.
    "diagnostic": "-v keepsyms=1 debug=0x108",
}

LEOPARD_BOOT_ARGS = "cpus=1"


def boot_args_for(os_profile: str, preset: str) -> str:
    parts = [BOOT_ARGS[preset]]
    if os_profile == "leopard":
        # KernelArch=i386-user32 selects both the i386 kernel and 32-bit userspace;
        # OpenCore adds -legacy itself.  Keep only the physical one-core topology here.
        parts.append(LEOPARD_BOOT_ARGS)
    return " ".join(part for part in parts if part)


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


def read_kext(oc_root: Path, bundle_path: str, minimum: str, maximum: str) -> dict:
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
        "Arch": "i386",
        "BundlePath": str(relative),
        "Comment": f"{bundle_id} {version}; statically checked i386 candidate",
        "Enabled": True,
        "ExecutablePath": executable_path,
        "MaxKernel": maximum,
        "MinKernel": minimum,
        "PlistPath": "Contents/Info.plist",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--oc-root", required=True, type=Path)
    parser.add_argument("--os", required=True, choices=tuple(KERNEL_RANGES))
    parser.add_argument("--kernel", required=True, choices=("vanilla", "custom"))
    parser.add_argument("--boot-preset", required=True, choices=tuple(BOOT_ARGS))
    parser.add_argument(
        "--runtime-profile", required=True, choices=("off", "legacy", "modern")
    )
    parser.add_argument("--driver", action="append", default=[])
    parser.add_argument("--kext", action="append", default=[])
    parser.add_argument("--acpi", action="append", default=[])
    parser.add_argument("--drop-duplicate-apic", action="store_true")
    parser.add_argument("--oc-version", default="UNKNOWN")
    args = parser.parse_args()

    with args.sample.open("rb") as handle:
        config = plistlib.load(handle)
    clear_samples(config)

    booter = config["Booter"]["Quirks"]
    booter["FixupAppleEfiImages"] = True
    booter["SetupVirtualMap"] = False
    if args.runtime_profile == "off":
        booter["EnableSafeModeSlide"] = False
        booter["EnableWriteUnprotector"] = False
        booter["ProvideCustomSlide"] = False
        booter["RebuildAppleMemoryMap"] = False
        booter["SyncRuntimePermissions"] = False
    elif args.runtime_profile == "legacy":
        # Darwin 9 i386 cannot consume the MAT-split OpenRuntime descriptors emitted by
        # RebuildAppleMemoryMap on OpenDuet: boot.efi leaves their VirtualStart at zero and
        # XNU panics in pmap_map. Keep OpenRuntime, but use its legacy write-unprotect path.
        booter["EnableSafeModeSlide"] = False
        booter["EnableWriteUnprotector"] = True
        booter["RebuildAppleMemoryMap"] = False
        booter["SyncRuntimePermissions"] = False
    else:
        booter["EnableWriteUnprotector"] = False
        booter["RebuildAppleMemoryMap"] = True
        booter["SyncRuntimePermissions"] = True

    config["ACPI"]["Add"] = [
        {"Comment": "User-supplied ACPI table", "Enabled": True, "Path": path}
        for path in args.acpi
    ]
    if args.drop_duplicate_apic:
        config["ACPI"]["Delete"] = [
            {
                "All": False,
                "Comment": "Drop duplicate Phoenix MADT; keep INTEL CALISTGA APIC",
                "Enabled": True,
                "OemTableId": b"\x09 APIC  ",
                "TableLength": 90,
                "TableSignature": b"APIC",
            }
        ]

    minimum, maximum = KERNEL_RANGES[args.os]
    config["Kernel"]["Add"] = [
        read_kext(args.oc_root, path, minimum, maximum) for path in args.kext
    ]
    emulate = config["Kernel"]["Emulate"]
    emulate["Cpuid1Data"] = b""
    emulate["Cpuid1Mask"] = b""
    emulate["DummyPowerManagement"] = True
    emulate["MinKernel"] = minimum
    emulate["MaxKernel"] = maximum

    quirks = config["Kernel"]["Quirks"]
    quirks["AppleCpuPmCfgLock"] = False
    quirks["LegacyCommpage"] = False
    quirks["ProvideCurrentCpuInfo"] = False

    scheme = config["Kernel"]["Scheme"]
    scheme["CustomKernel"] = args.kernel == "custom"
    scheme["FuzzyMatch"] = True
    scheme["KernelArch"] = "i386-user32" if args.os == "leopard" else "i386"
    scheme["KernelCache"] = "Auto"

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

    config["NVRAM"]["Add"] = {
        "4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14": {
            "DefaultBackgroundColor": b"\x00\x00\x00\x00"
        },
        "7C436110-AB2A-4BBB-A880-FE41995C9F82": {
            "boot-args": boot_args_for(args.os, args.boot_preset),
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
    generic.update(
        {
            "AdviseFeatures": False,
            "MLB": "W0000000000000001",
            "MaxBIOSVersion": False,
            "ProcessorType": 0,
            "ROM": b"ACER43",
            "SpoofVendor": True,
            "SystemMemoryStatus": "Auto",
            "SystemProductName": "MacBook2,1",
            "SystemSerialNumber": "W00000000001",
            "SystemUUID": str(
                uuid.uuid5(uuid.NAMESPACE_DNS, "aspire4310-legacy-macos")
            ).upper(),
        }
    )

    config["UEFI"]["Drivers"] = [
        {
            "Arguments": "",
            "Comment": "Aspire 4310 minimal legacy boot driver",
            "Enabled": True,
            "LoadEarly": False,
            "Path": driver,
        }
        for driver in args.driver
    ]
    input_config = config["UEFI"]["Input"]
    input_config["KeyForgetThreshold"] = 9
    input_config["KeySupport"] = True
    input_config["KeySupportMode"] = "V1"
    config["UEFI"]["Output"]["ProvideConsoleGop"] = True
    config["UEFI"]["Output"]["Resolution"] = "Max"
    config["UEFI"]["Quirks"]["ReleaseUsbOwnership"] = True
    # OpenDuet already provides variable routing; OpenRuntime is not required for it here.
    config["UEFI"]["Quirks"]["RequestBootVarRouting"] = False

    config["#Revision"] = f"Aspire 4310 profile generated from OpenCore {args.oc_version} Sample.plist"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as handle:
        plistlib.dump(config, handle, fmt=plistlib.FMT_XML, sort_keys=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
