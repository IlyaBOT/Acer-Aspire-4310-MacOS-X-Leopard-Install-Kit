#!/usr/bin/env python3
from pathlib import Path
import sys


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        print(f"[o2micro-cardinit] ERROR: {label}: expected 1 match, found {count}", file=sys.stderr)
        raise SystemExit(1)
    path.write_text(text.replace(old, new, 1))
    print(f"[o2micro-cardinit] {label}")


def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/VoodooSDHCI", file=sys.stderr)
        raise SystemExit(2)

    cpp = Path(sys.argv[1]).resolve() / "VoodooSDHC.cpp"
    if not cpp.is_file():
        print(f"[o2micro-cardinit] ERROR: missing {cpp}", file=sys.stderr)
        raise SystemExit(1)

    replacements = [
        (
            "\tSDCommand(slot, SD_ALL_SEND_CID, SDCR2, 0);",
            "\tif (!SDCommand(slot, SD_ALL_SEND_CID, SDCR2, 0))\n\t\treturn false;",
            "check CMD2",
        ),
        (
            "\tSDCommand(slot, SD_SET_RELATIVE_ADDR, SDCR3, 0);",
            "\tif (!SDCommand(slot, SD_SET_RELATIVE_ADDR, SDCR3, 0))\n\t\treturn false;",
            "check CMD3",
        ),
        (
            "\tcalcClock(slot, 25000000);",
            "\tif (!calcClock(slot, 25000000))\n\t\treturn false;",
            "check 25MHz clock switch",
        ),
        (
            "\tSDCommand(slot, SD_SEND_CSD, SDCR9, this->RCA << 16);",
            "\tif (!SDCommand(slot, SD_SEND_CSD, SDCR9, this->RCA << 16))\n\t\treturn false;",
            "check CMD9",
        ),
        (
            "\tSDCommand(slot, SD_SELECT_CARD, SDCR7, this->RCA << 16);",
            "\tif (!SDCommand(slot, SD_SELECT_CARD, SDCR7, this->RCA << 16))\n\t\treturn false;",
            "check CMD7",
        ),
    ]

    for old, new, label in replacements:
        replace_once(cpp, old, new, label)

    print("[o2micro-cardinit] remaining mandatory cardInit commands now fail fast")


if __name__ == "__main__":
    main()
