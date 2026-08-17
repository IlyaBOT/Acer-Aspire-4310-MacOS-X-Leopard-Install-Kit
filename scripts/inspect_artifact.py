#!/usr/bin/env python3
"""Inspect legacy macOS kexts, Mach-O kernels, and EFI PE binaries."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import struct
import sys
from pathlib import Path


CPU_NAMES = {
    7: "i386",
    0x01000007: "x86_64",
    18: "ppc",
    0x01000012: "ppc64",
}
PE_NAMES = {0x014C: "i386", 0x8664: "x86_64"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def binary_arches(path: Path) -> list[str]:
    data = path.read_bytes()[:4096]
    if len(data) < 4:
        return []

    magic = data[:4]
    thin = {
        b"\xce\xfa\xed\xfe": "i386",
        b"\xfe\xed\xfa\xce": "i386",
        b"\xcf\xfa\xed\xfe": "x86_64",
        b"\xfe\xed\xfa\xcf": "x86_64",
    }
    if magic in thin:
        return [thin[magic]]

    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        if len(data) < 8:
            return []
        count = struct.unpack(">I", data[4:8])[0]
        stride = 24 if magic == b"\xca\xfe\xba\xbf" else 20
        arches: list[str] = []
        for index in range(min(count, 32)):
            start = 8 + index * stride
            if start + 4 > len(data):
                break
            cpu_type = struct.unpack(">I", data[start : start + 4])[0]
            arches.append(CPU_NAMES.get(cpu_type, f"cpu-{cpu_type:#x}"))
        return list(dict.fromkeys(arches))

    if data[:2] == b"MZ" and len(data) >= 0x40:
        pe_offset = struct.unpack("<I", data[0x3C:0x40])[0]
        if pe_offset + 6 <= len(data) and data[pe_offset : pe_offset + 4] == b"PE\0\0":
            machine = struct.unpack("<H", data[pe_offset + 4 : pe_offset + 6])[0]
            return [PE_NAMES.get(machine, f"pe-{machine:#x}")]
    return []


def inspect_binary(path: Path) -> dict[str, object]:
    return {
        "path": str(path),
        "sha256": sha256(path),
        "architectures": binary_arches(path),
        "size": path.stat().st_size,
    }


def inspect_kext(path: Path) -> dict[str, object]:
    info_path = path / "Contents" / "Info.plist"
    if not info_path.is_file():
        raise ValueError(f"missing Contents/Info.plist: {path}")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)

    executable_name = info.get("CFBundleExecutable", "")
    executable = path / "Contents" / "MacOS" / executable_name if executable_name else None
    result: dict[str, object] = {
        "path": str(path),
        "bundle_id": info.get("CFBundleIdentifier", "UNKNOWN"),
        "version": info.get("CFBundleVersion", "UNKNOWN"),
        "minimum_os": info.get("LSMinimumSystemVersion", "UNSPECIFIED"),
        "libraries": info.get("OSBundleLibraries", {}),
        "executable": executable_name,
        "architectures": [],
        "sha256": "PLIST_ONLY",
    }
    if executable_name:
        if executable is None or not executable.is_file():
            raise ValueError(f"missing declared executable {executable_name}: {path}")
        result["architectures"] = binary_arches(executable)
        result["sha256"] = sha256(executable)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--binary", type=Path)
    target.add_argument("--kext", type=Path)
    parser.add_argument("--require-arch", choices=("i386", "x86_64"))
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    try:
        result = inspect_kext(args.kext) if args.kext else inspect_binary(args.binary)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    arches = result.get("architectures", [])
    # Plist-only injector kexts have no executable architecture to check.  Every
    # kext that does declare an executable, and every standalone binary, must
    # satisfy --require-arch.
    plist_only_kext = args.kext is not None and not result.get("executable")
    if args.require_arch and args.require_arch not in arches and not plist_only_kext:
        print(
            f"ERROR: required architecture {args.require_arch} not present in "
            f"{result['path']} (found: {','.join(arches) or 'unknown'})",
            file=sys.stderr,
        )
        return 3
    if not args.quiet:
        print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
