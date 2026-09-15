#!/usr/bin/env python3
"""Apply the audited ASUS Eee PC 1215P OpenCore delta to a generated config."""

from __future__ import annotations

import argparse
import plistlib
import uuid
from pathlib import Path

GPU_PATH = "PciRoot(0x0)/Pci(0x2,0x0)"
CURSOR_FIND = bytes.fromhex("8b550883bab0000000017e36890424e832bbffff")
CURSOR_REPLACE = bytes.fromhex("b800000002909090909090909090eb0400000000")


def patch(config: dict) -> None:
    # Physical machine: GMA3150 A011/A012, 1366x768 single-link HannStar
    # HSD121PHW1. Values are the GMA950 laptop properties documented by
    # Dortania, with the Calistoga 0x27A2 fake device-id.
    config["DeviceProperties"]["Add"][GPU_PATH] = {
        "device-id": bytes.fromhex("A2270000"),
        "model": "GMA 950",
        "AAPL,HasPanel": bytes.fromhex("01000000"),
        "AAPL01,BacklightIntensity": bytes.fromhex("3F000008"),
        "AAPL01,BootDisplay": bytes.fromhex("01000000"),
        "AAPL01,DataJustify": bytes.fromhex("01000000"),
        "AAPL01,DualLink": bytes.fromhex("00"),
    }

    patches = config["Kernel"]["Patch"]
    patches.append(
        {
            "Arch": "i386",
            "Base": "",
            "Comment": "GMA 3150 Cursor corruption fix",
            "Count": 0,
            "Enabled": True,
            "Find": CURSOR_FIND,
            "Identifier": "com.apple.driver.AppleIntelIntegratedFramebuffer",
            "Limit": 0,
            "Mask": b"",
            "MaxKernel": "11.99.99",
            "MinKernel": "8.0.0",
            "Replace": CURSOR_REPLACE,
            "ReplaceMask": b"",
            "Skip": 0,
        }
    )

    scheme = config["Kernel"]["Scheme"]
    scheme["KernelArch"] = "i386"
    scheme["CustomKernel"] = True
    scheme["FuzzyMatch"] = True

    # The historical 10.3.0 Atom/legacy kernels are i386-only. Explicitly keep
    # arch=i386 in boot-args too: period kernel packages did the same to avoid
    # instant reboot on CPUs that the vanilla kernel did not recognize.
    nvram = config["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]
    args = nvram.get("boot-args", "").split()
    if "arch=i386" not in args:
        args.append("arch=i386")
    nvram["boot-args"] = " ".join(args)

    # Machine-specific ACPI audit already confirmed PCI0._UID == 0, so no
    # PCI-root UID patch is injected here.
    generic = config["PlatformInfo"]["Generic"]
    generic.update(
        {
            "MLB": "W0000000000001215",
            "ROM": b"AS1215",
            "SystemProductName": "MacBook2,1",
            "SystemSerialNumber": "W00000001215",
            "SystemUUID": str(
                uuid.uuid5(uuid.NAMESPACE_DNS, "asus-eee-pc-1215p-legacy-macos")
            ).upper(),
        }
    )

    for driver in config["UEFI"]["Drivers"]:
        if "Comment" in driver and "Aspire 4310" in driver["Comment"]:
            driver["Comment"] = driver["Comment"].replace(
                "Aspire 4310", "ASUS Eee PC 1215P"
            )

    config["#Revision"] = (
        "ASUS Eee PC 1215P audited profile; Atom N570 / GMA3150; "
        "Snow Leopard i386 custom-kernel bring-up"
    )


def validate(config: dict) -> None:
    props = config["DeviceProperties"]["Add"].get(GPU_PATH, {})
    assert props.get("device-id") == bytes.fromhex("A2270000")
    assert props.get("AAPL01,DualLink") == b"\x00"
    assert config["Kernel"]["Scheme"]["KernelArch"] == "i386"
    assert config["Kernel"]["Scheme"]["CustomKernel"] is True
    assert any(
        entry.get("Identifier") == "com.apple.driver.AppleIntelIntegratedFramebuffer"
        and entry.get("Find") == CURSOR_FIND
        and entry.get("Replace") == CURSOR_REPLACE
        and entry.get("Enabled") is True
        for entry in config["Kernel"]["Patch"]
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    args = parser.parse_args()

    with args.config.open("rb") as handle:
        config = plistlib.load(handle)
    patch(config)
    validate(config)
    with args.config.open("wb") as handle:
        plistlib.dump(config, handle, fmt=plistlib.FMT_XML, sort_keys=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
