#!/usr/bin/env python3
"""Apply the narrow OpenCore overrides required by the XNU build VM."""

from __future__ import annotations

import argparse
import os
import plistlib
import tempfile
from pathlib import Path


PARTITION_DRIVER = "OpenPartitionDxe.efi"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("--resolution", default="1024x768@32")
    args = parser.parse_args()

    with args.config.open("rb") as handle:
        config = plistlib.load(handle)
    original_mode = args.config.stat().st_mode & 0o777

    output = config["UEFI"]["Output"]
    output["Resolution"] = args.resolution
    output["UIScale"] = 1

    # QEMU provides a hardware AppleSMC device, so the VM must not inject the
    # physical-machine FakeSMC fallback into Leopard's fixed-address mkext.
    # Avoiding that module also avoids the OVMF low-memory collision without a
    # relocation block, whose final copy is unsafe with this IA32 EfiBoot path.
    kexts = config["Kernel"]["Add"]
    kexts[:] = [
        entry
        for entry in kexts
        if entry.get("BundlePath", "").casefold() != "fakesmc.kext"
    ]

    booter = config["Booter"]["Quirks"]
    booter["AllowRelocationBlock"] = False

    drivers = config["UEFI"]["Drivers"]
    matching = [entry for entry in drivers if entry.get("Path") == PARTITION_DRIVER]
    if matching:
        entry = matching[0]
        entry.update(
            {
                "Arguments": "",
                "Comment": "QEMU Apple Partition Map support",
                "Enabled": True,
                "LoadEarly": False,
            }
        )
        drivers[:] = [
            current
            for current in drivers
            if current is entry or current.get("Path") != PARTITION_DRIVER
        ]
        drivers.remove(entry)
        drivers.insert(0, entry)
    else:
        drivers.insert(
            0,
            {
                "Arguments": "",
                "Comment": "QEMU Apple Partition Map support",
                "Enabled": True,
                "LoadEarly": False,
                "Path": PARTITION_DRIVER,
            },
        )

    args.config.parent.mkdir(parents=True, exist_ok=True)
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=args.config.parent, prefix="config.", delete=False
        ) as handle:
            temporary_name = handle.name
            plistlib.dump(config, handle, fmt=plistlib.FMT_XML, sort_keys=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, original_mode)
        os.replace(temporary_name, args.config)
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)

    print(
        f"Configured QEMU ESP: {PARTITION_DRIVER}, "
        f"resolution {args.resolution}, UIScale 1, hardware AppleSMC profile"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
