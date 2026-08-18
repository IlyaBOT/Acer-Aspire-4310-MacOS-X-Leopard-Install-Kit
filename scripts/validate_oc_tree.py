#!/usr/bin/env python3
"""Validate that enabled OpenCore config entries resolve inside one staged ESP."""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    args = parser.parse_args()
    config_path = args.config.resolve()
    oc_root = config_path.parent
    esp_root = oc_root.parent.parent
    with config_path.open("rb") as handle:
        config = plistlib.load(handle)

    errors: list[str] = []
    for entry in config["ACPI"]["Add"]:
        if entry.get("Enabled") and not (oc_root / "ACPI" / entry["Path"]).is_file():
            fail(errors, f"missing ACPI/Add file: {entry['Path']}")

    bundle_ids: dict[str, str] = {}
    dependency_sets: list[tuple[str, dict[str, str]]] = []
    for entry in config["Kernel"]["Add"]:
        if not entry.get("Enabled"):
            continue
        bundle = oc_root / "Kexts" / entry["BundlePath"]
        plist_path = bundle / entry["PlistPath"]
        if not bundle.is_dir():
            fail(errors, f"missing Kernel/Add bundle: {entry['BundlePath']}")
            continue
        if not plist_path.is_file():
            fail(errors, f"missing kext plist: {entry['BundlePath']}/{entry['PlistPath']}")
            continue
        with plist_path.open("rb") as handle:
            info = plistlib.load(handle)
        bundle_id = info.get("CFBundleIdentifier", "")
        if not bundle_id:
            fail(errors, f"missing CFBundleIdentifier: {entry['BundlePath']}")
        elif bundle_id in bundle_ids:
            fail(errors, f"duplicate bundle id {bundle_id}: {bundle_ids[bundle_id]} and {entry['BundlePath']}")
        else:
            bundle_ids[bundle_id] = entry["BundlePath"]
        dependency_sets.append((entry["BundlePath"], info.get("OSBundleLibraries", {})))
        executable = entry.get("ExecutablePath", "")
        if executable and not (bundle / executable).is_file():
            fail(errors, f"missing kext executable: {entry['BundlePath']}/{executable}")

    for bundle_path, dependencies in dependency_sets:
        for dependency in dependencies:
            if dependency.startswith("com.apple."):
                continue
            if dependency not in bundle_ids:
                fail(errors, f"unsatisfied non-Apple dependency {dependency} for {bundle_path}")

    seen_drivers: set[str] = set()
    for entry in config["UEFI"]["Drivers"]:
        if not entry.get("Enabled"):
            continue
        path = entry["Path"]
        if path in seen_drivers:
            fail(errors, f"duplicate UEFI driver: {path}")
        seen_drivers.add(path)
        if not (oc_root / "Drivers" / path).is_file():
            fail(errors, f"missing UEFI/Drivers file: {path}")

    if "Ps2KeyboardDxe.efi" in seen_drivers:
        input_config = config["UEFI"]["Input"]
        if not input_config["KeySupport"]:
            fail(errors, "Ps2KeyboardDxe requires UEFI/Input/KeySupport")
        if input_config["KeySupportMode"] != "V1":
            fail(errors, "Aspire 4310 PS/2 input requires KeySupportMode V1")

    visibility = esp_root / "EFI" / "BOOT" / ".contentVisibility"
    if not visibility.is_file() or visibility.read_bytes() != b"Disabled":
        fail(errors, "EFI bootstrap must be hidden with .contentVisibility=Disabled")

    for entry in config["Misc"]["Tools"]:
        if entry.get("Enabled") and not (oc_root / "Tools" / entry["Path"]).is_file():
            fail(errors, f"missing Misc/Tools file: {entry['Path']}")

    if config["Kernel"]["Scheme"]["CustomKernel"]:
        kernels = esp_root / "Kernels"
        if not kernels.is_dir() or not any(path.is_file() for path in kernels.iterdir()):
            fail(errors, "CustomKernel is enabled but ESP/Kernels has no artifact")

    kernel_arch = config["Kernel"]["Scheme"]["KernelArch"]
    if kernel_arch.startswith("i386") and config["Booter"]["Quirks"]["SetupVirtualMap"]:
        fail(errors, "SetupVirtualMap is incompatible with 32-bit kernels")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Validated enabled file references and kext dependencies: {config_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
