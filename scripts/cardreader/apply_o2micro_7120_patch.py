#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

EXPECTED_UPSTREAM = "be8dc240a3b979d629660daea0d59c108ea86311"


def die(message: str) -> None:
    print(f"[o2micro-patch] ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        die(f"{label}: expected one exact match in {path}, found {count}")
    path.write_text(text.replace(old, new, 1))
    print(f"[o2micro-patch] {label}")


def regex_replace_once(path: Path, pattern: str, replacement: str, label: str) -> None:
    text = path.read_text()
    new_text, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        die(f"{label}: expected one regex match in {path}, found {count}")
    path.write_text(new_text)
    print(f"[o2micro-patch] {label}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Patch coolstar/VoodooSDHCI for conservative O2Micro 1217:7120 diagnostics"
    )
    parser.add_argument("source", type=Path, help="VoodooSDHCI source directory")
    args = parser.parse_args()

    root = args.source.resolve()
    cpp = root / "VoodooSDHC.cpp"
    hdr = root / "VoodooSDHC.h"
    plist = root / "Info.plist"
    for path in (cpp, hdr, plist):
        if not path.is_file():
            die(f"missing {path}")

    # This first build is intentionally conservative: read-only, 1-bit bus,
    # single-block PIO.  The SDMA event infrastructure remains compiled because
    # this old driver also uses it for hot-plug polling, but data commands do not
    # set SDHCI_TRNS_DMA when USE_SDMA is zero.
    replace_once(cpp, "//#define __DEBUG__\t1", "#define __DEBUG__\t1", "enable debug logging")
    replace_once(cpp, "//#define READONLY_DRIVER\t1", "#define READONLY_DRIVER\t1", "force read-only test mode")
    replace_once(cpp, "#define WIDE_BUS_MODE\t1", "//#define WIDE_BUS_MODE\t1", "disable 4-bit mode for first O2Micro test")
    replace_once(cpp, "#define USE_MULTIBLOCK\t1", "#define USE_MULTIBLOCK\t0", "disable multiblock I/O")
    replace_once(cpp, "#define USE_SDMA 1", "#define USE_SDMA 0", "force PIO data path")

    replace_once(
        cpp,
        "#define SDMA_RETRY_COUNT 5\n",
        "#define SDMA_RETRY_COUNT 5\n"
        "\n"
        "/* Fail-safe polling limits.  The original code contains several unbounded\n"
        " * waits; on O2Micro 1217:7120 one of those stalls IOKit and WindowServer. */\n"
        "#define SDHCI_POLL_STEP_US          50U\n"
        "#define SDHCI_CMD_TIMEOUT_US        500000U\n"
        "#define SDHCI_RESET_TIMEOUT_US      100000U\n"
        "#define SDHCI_CLOCK_TIMEOUT_US      100000U\n"
        "#define SDHCI_INT_TIMEOUT_US        5000000U\n",
        "add bounded polling timeouts",
    )

    replace_once(
        hdr,
        "\t\tkCardNotPresent,\n\t\tkCardIsPresent,\n\t\tkCardRemount\n",
        "\t\tkCardNotPresent,\n\t\tkCardIsPresent,\n\t\tkCardRemount,\n\t\tkCardInitFailed\n",
        "add failed-initialization media state",
    )
    replace_once(
        hdr,
        "\tvoid\t\t\tReset( UInt8 slot, UInt8 type );",
        "\tbool\t\t\tReset( UInt8 slot, UInt8 type );",
        "make host reset report timeout",
    )

    # Make this build match the Acer's O2Micro SD function while retaining the
    # two Ricoh IDs carried by the upstream VoodooSDHCI source.
    replace_once(
        plist,
        "<string>0x08221180 0x08231180</string>",
        "<string>0x08221180 0x08231180 0x71201217</string>",
        "add PCI ID 1217:7120",
    )

    reset_fn = r'''bool VoodooSDHC::Reset(UInt8 slot, UInt8 type)
{
	switch(type) {
		case CMD_RESET:
			this->PCIRegP[slot]->SoftwareReset = CMD_RESET;
			break;
		case DAT_RESET:
			this->PCIRegP[slot]->SoftwareReset = DAT_RESET;
			break;
		default:
			this->PCIRegP[slot]->SoftwareReset = FULL_RESET;
			break;
	}
	::OSSynchronizeIO();

	for (UInt32 waited = 0; waited < SDHCI_RESET_TIMEOUT_US; waited += SDHCI_POLL_STEP_US) {
		if (this->PCIRegP[slot]->SoftwareReset == 0)
			return true;
		IODelay(SDHCI_POLL_STEP_US);
	}

	IOLog("VoodooSDHCI/O2: reset timeout type=0x%02x PresentState=0x%08x NIS=0x%04x EIS=0x%04x\\n",
		type,
		this->PCIRegP[slot]->PresentState,
		this->PCIRegP[slot]->NormalIntStatus,
		this->PCIRegP[slot]->ErrorIntStatus);
	return false;
}'''
    regex_replace_once(
        cpp,
        r"void VoodooSDHC::Reset\(UInt8 slot, UInt8 type\)\n\{.*?\n\}\n\n/\*\n \* SDCommand:",
        reset_fn + "\n\n/*\n * SDCommand:",
        "bound controller reset wait",
    )

    sdcommand_fn = r'''bool VoodooSDHC::SDCommand(UInt8 slot, UInt8 command, UInt16 response,
								UInt32 arg) {
	if (command != 0) {
		UInt32 waited = 0;
		while (this->PCIRegP[slot]->PresentState & ComInhibitCMD) {
			if (waited >= SDHCI_CMD_TIMEOUT_US) {
				IOLog("VoodooSDHCI/O2: timeout BEFORE CMD%u arg=0x%08x PresentState=0x%08x NIS=0x%04x EIS=0x%04x\\n",
					command, arg,
					this->PCIRegP[slot]->PresentState,
					this->PCIRegP[slot]->NormalIntStatus,
					this->PCIRegP[slot]->ErrorIntStatus);
				Reset(slot, CMD_RESET);
				return false;
			}
			IODelay(SDHCI_POLL_STEP_US);
			waited += SDHCI_POLL_STEP_US;
		}
	}

	switch(response) { //See SD Host Controller Spec Version 2.00 Page 30
		case R0:  response = 0; break;
		case R1:  response = BIT4|BIT3|BIT1; break;
		case R1b: response = BIT4|BIT3|BIT1|BIT0; break;
		case R2:  response = BIT3|BIT0; break;
		case R3:  response = BIT1; break;
		case R4:  response = BIT1; break;
		case R5:  response = BIT4|BIT3|BIT1; break;
		case R5b: response = BIT4|BIT3|BIT1|BIT0; break;
		case R6:  response = BIT4|BIT3|BIT1; break;
		case R7:  response = BIT4|BIT3|BIT1; break;
	}

	this->PCIRegP[slot]->Argument = arg;

	if (command == 17 || command == 24)
		response |= BIT5;

	if (command == SD_READ_MULTIPLE_BLOCK) {
		response |= BIT5;
		this->PCIRegP[0]->TransferMode =
			SDHCI_TRNS_READ | SDHCI_TRNS_MULTI |
			SDHCI_TRNS_BLK_CNT_EN | SDHCI_TRNS_ACMD12
#if USE_SDMA
			| SDHCI_TRNS_DMA
#endif
		;
	}

	if (command == SD_WRITE_MULTIPLE_BLOCK) {
		response |= BIT5;
		this->PCIRegP[0]->TransferMode = SDHCI_TRNS_MULTI |
			SDHCI_TRNS_BLK_CNT_EN | SDHCI_TRNS_ACMD12
#if USE_SDMA
			| SDHCI_TRNS_DMA
#endif
		;
	}

	/* Clear stale command/error status before issuing a new command. */
	this->PCIRegP[slot]->NormalIntStatus = CmdComplete | ErrorInterrupt;
	this->PCIRegP[slot]->ErrorIntStatus = 0xffff;
	::OSSynchronizeIO();

#ifdef __DEBUG__
	IOLog("VoodooSDHCI/O2: -> CMD%u arg=0x%08x PS=0x%08x\\n",
		command, arg, this->PCIRegP[slot]->PresentState);
#endif
	this->PCIRegP[slot]->Command = (command << 8) | response;
	::OSSynchronizeIO();
	IODelay(10);

	for (UInt32 waited = 0; waited < SDHCI_CMD_TIMEOUT_US; waited += SDHCI_POLL_STEP_US) {
		UInt32 ps = this->PCIRegP[slot]->PresentState;
		UInt16 nis = this->PCIRegP[slot]->NormalIntStatus;
		UInt16 eis = this->PCIRegP[slot]->ErrorIntStatus;

		if ((nis & ErrorInterrupt) || eis) {
			IOLog("VoodooSDHCI/O2: error CMD%u arg=0x%08x PS=0x%08x NIS=0x%04x EIS=0x%04x RESP0=0x%08x\\n",
				command, arg, ps, nis, eis, this->PCIRegP[slot]->Response[0]);
			Reset(slot, CMD_RESET);
			return false;
		}

		if (!(ps & ComInhibitCMD)) {
#ifdef __DEBUG__
			IOLog("VoodooSDHCI/O2: <- CMD%u RESP0=0x%08x NIS=0x%04x\\n",
				command, this->PCIRegP[slot]->Response[0], nis);
#endif
			return true;
		}

		IODelay(SDHCI_POLL_STEP_US);
	}

	IOLog("VoodooSDHCI/O2: timeout AFTER CMD%u arg=0x%08x PresentState=0x%08x NIS=0x%04x EIS=0x%04x RESP0=0x%08x\\n",
		command, arg,
		this->PCIRegP[slot]->PresentState,
		this->PCIRegP[slot]->NormalIntStatus,
		this->PCIRegP[slot]->ErrorIntStatus,
		this->PCIRegP[slot]->Response[0]);
	Reset(slot, CMD_RESET);
	Reset(slot, DAT_RESET);
	return false;
}'''
    regex_replace_once(
        cpp,
        r"bool VoodooSDHC::SDCommand\(UInt8 slot, UInt8 command, UInt16 response,\n\s*UInt32 arg\) \{.*?\n\}\n\n/\*\n \* calcClock:",
        sdcommand_fn + "\n\n/*\n * calcClock:",
        "replace indefinite command spin with bounded traced command path",
    )

    calcclock_fn = r'''bool VoodooSDHC::calcClock(UInt8 slot, UInt32 clockspeed) {
	UInt32 baseClock;
	UInt32 div;

	this->PCIRegP[slot]->ClockControl = 0;
	this->PCIRegP[slot]->ClockControl |= BIT0;
	::OSSynchronizeIO();

	UInt32 waited = 0;
	while (!(this->PCIRegP[slot]->ClockControl & BIT1)) {
		if (waited >= SDHCI_CLOCK_TIMEOUT_US) {
			IOLog("VoodooSDHCI/O2: internal clock did not become stable, ClockControl=0x%04x\\n",
				this->PCIRegP[slot]->ClockControl);
			return false;
		}
		IODelay(SDHCI_POLL_STEP_US);
		waited += SDHCI_POLL_STEP_US;
	}

	baseClock = ((this->PCIRegP[slot]->Capabilities[0] & 0x3F00) >> 8);
	baseClock *= 1000000;
	if (baseClock == 0) {
		IOLog("VoodooSDHCI/O2: controller reports zero base clock, caps=0x%08x\\n",
			this->PCIRegP[slot]->Capabilities[0]);
		return false;
	}

	IOLog("VoodooSDHCI/O2: BaseClock=%uMHz HostControllerVer=0x%04x Caps=0x%08x\\n",
		baseClock / 1000000,
		this->PCIRegP[slot]->HostControllerVer,
		this->PCIRegP[slot]->Capabilities[0]);

	for (div = 1; (baseClock / div) > clockspeed; div <<= 1)
		;

	IOLog("VoodooSDHCI/O2: SD Clock=%uKHz divider=%u\\n",
		(baseClock / div) / 1000, div);

	div = (div << 7) & 0xFF000;
	this->PCIRegP[slot]->ClockControl |= div;
	this->PCIRegP[slot]->ClockControl |= BIT2;
	::OSSynchronizeIO();
	return true;
}'''
    regex_replace_once(
        cpp,
        r"bool VoodooSDHC::calcClock\(UInt8 slot, UInt32 clockspeed\) \{.*?\n\}\n\n/\*\n \* powerSD:",
        calcclock_fn + "\n\n/*\n * powerSD:",
        "fix clock-stable test and add timeout",
    )

    waitint_fn = r'''bool VoodooSDHC::waitIntStatus(UInt32 maskBits)
{
	for (UInt32 waited = 0; waited < SDHCI_INT_TIMEOUT_US; waited += SDHCI_POLL_STEP_US) {
		UInt32 nis = PCIRegP[0]->NormalIntStatus;
		if (nis & ErrorInterrupt) {
			IOLog("VoodooSDHCI/O2: interrupt error waiting mask=0x%08x NIS=0x%04x EIS=0x%04x\\n",
				maskBits, (UInt16)nis, PCIRegP[0]->ErrorIntStatus);
			return false;
		}
		if (nis & maskBits) {
			PCIRegP[0]->NormalIntStatus = maskBits;
			return true;
		}
		IODelay(SDHCI_POLL_STEP_US);
	}
	IOLog("VoodooSDHCI/O2: interrupt timeout mask=0x%08x NIS=0x%04x EIS=0x%04x PS=0x%08x\\n",
		maskBits,
		PCIRegP[0]->NormalIntStatus,
		PCIRegP[0]->ErrorIntStatus,
		PCIRegP[0]->PresentState);
	return false;
}'''
    regex_replace_once(
        cpp,
        r"bool VoodooSDHC::waitIntStatus\(UInt32 maskBits\)\n\{.*?\n\}\n\n/\*\n \* readBlockMulti_pio:",
        waitint_fn + "\n\n/*\n * readBlockMulti_pio:",
        "fix unreachable interrupt timeout",
    )

    report_media_fn = r'''IOReturn VoodooSDHC::reportMediaState(bool *mediaPresent, bool *changedState)
{
	IOLockLock(mediaStateLock);

	bool presence = isCardPresent(0);

	/* A failed initialization is latched until physical removal.  This avoids
	 * retrying a broken controller transaction every poll and starving IOKit. */
	if (!presence) {
		bool wasMounted = (cardPresence == kCardIsPresent);
		if (cardPresence == kCardInitFailed)
			IOLog("VoodooSDHCI/O2: card removed after failed initialization; re-arming slot\\n");
		cardPresence = kCardNotPresent;
		*mediaPresent = false;
		*changedState = wasMounted;
		IOLockUnlock(mediaStateLock);
		return kIOReturnSuccess;
	}

	if (cardPresence == kCardInitFailed) {
		*mediaPresent = false;
		*changedState = false;
		IOLockUnlock(mediaStateLock);
		return kIOReturnSuccess;
	}

	if (cardPresence == kCardRemount) {
		*changedState = true;
		cardPresence = kCardNotPresent;
	} else if (cardPresence == kCardIsPresent) {
		*changedState = false;
	} else {
		if (!Reset(0, FULL_RESET) || !cardInit(0)) {
			IOLog("VoodooSDHCI/O2: card initialization FAILED; media kept offline until removal\\n");
			Reset(0, FULL_RESET);
			cardPresence = kCardInitFailed;
			*mediaPresent = false;
			*changedState = false;
			IOLockUnlock(mediaStateLock);
			return kIOReturnSuccess;
		}
		cardPresence = kCardIsPresent;
		*changedState = true;
	}

	*mediaPresent = (cardPresence == kCardIsPresent);
	IOLockUnlock(mediaStateLock);
	return kIOReturnSuccess;
}'''
    regex_replace_once(
        cpp,
        r"IOReturn VoodooSDHC::reportMediaState\(bool \*mediaPresent, bool \*changedState\)\n\{.*?\n\}\n\n#ifndef __LP64__",
        report_media_fn + "\n\n#ifndef __LP64__",
        "keep failed media offline instead of wedging IOKit",
    )

    # Make card initialization fail-fast at the command sequence that wedged the
    # Acer.  The legacy ACMD41 branch was also an unbounded do/while loop.
    replace_once(
        cpp,
        "\tisHighCapacity = false;\n\tcalcClock(slot, 400000);\n\tpowerSD(slot);\n\tSDCommand(slot, SD_GO_IDLE_STATE, SDCR0, 0);\n\tIODelay(30000);\n\tSDCommand(slot, SD_SEND_IF_COND, SDCR8, 0x000001AA);",
        "\tisHighCapacity = false;\n\tif (!calcClock(slot, 400000))\n\t\treturn false;\n\tpowerSD(slot);\n\tif (!SDCommand(slot, SD_GO_IDLE_STATE, SDCR0, 0))\n\t\treturn false;\n\tIODelay(30000);\n\tbool cmd8OK = SDCommand(slot, SD_SEND_IF_COND, SDCR8, 0x000001AA);",
        "make CMD0/CMD8 initialization fail-fast",
    )
    replace_once(
        cpp,
        "\tif(this->PCIRegP[slot]->PresentState & ComInhibitCMD) {",
        "\tif(!cmd8OK || (this->PCIRegP[slot]->PresentState & ComInhibitCMD)) {",
        "treat CMD8 timeout/error as legacy-card path",
    )
    replace_once(
        cpp,
        "\t\tSDCommand(slot, SD_GO_IDLE_STATE, SDCR0, 0);\n\t\tdo {\n\t\t\tSDCommand(slot, SD_APP_CMD, SDCR55, 0);\n\t\t\tSDCommand(slot, SD_APP_OP_COND, SDACR41, 0x00FF8000);\n\t\t\tIODelay(1000);\n\t\t} while (!(this->PCIRegP[slot]->Response[0] & BIT31));",
        "\t\tif (!SDCommand(slot, SD_GO_IDLE_STATE, SDCR0, 0))\n\t\t\treturn false;\n\t\tbool ready = false;\n\t\tfor (int i = 0; i < 80; i++) {\n\t\t\tif (!SDCommand(slot, SD_APP_CMD, SDCR55, 0) ||\n\t\t\t\t!SDCommand(slot, SD_APP_OP_COND, SDACR41, 0x00FF8000))\n\t\t\t\treturn false;\n\t\t\tif (this->PCIRegP[slot]->Response[0] & BIT31) {\n\t\t\t\tready = true;\n\t\t\t\tbreak;\n\t\t\t}\n\t\t\tIODelay(25000);\n\t\t}\n\t\tif (!ready) {\n\t\t\tIOLog(\"VoodooSDHCI/O2: legacy ACMD41 never became ready\\n\");\n\t\t\treturn false;\n\t\t}",
        "bound legacy ACMD41 loop",
    )
    replace_once(
        cpp,
        "\t\t\tSDCommand(slot, SD_APP_CMD, SDCR55, 0);",
        "\t\t\tif (!SDCommand(slot, SD_APP_CMD, SDCR55, 0))\n\t\t\t\treturn false;",
        "check CMD55 in SD 2.0 loop",
    )
    replace_once(
        cpp,
        "\t\t\tSDCommand(slot, SD_APP_OP_COND, SDACR41, 0x40FF8000);",
        "\t\t\tif (!SDCommand(slot, SD_APP_OP_COND, SDACR41, 0x40FF8000))\n\t\t\t\treturn false;",
        "check ACMD41 in SD 2.0 loop",
    )

    # The current data path branches on the numeric value of USE_SDMA, so zero
    # selects the existing PIO routines.  In SDCommand, however, upstream used
    # #ifdef and would still set the DMA transfer bit.  The function replacement
    # above intentionally changes only those two sites to #if USE_SDMA.

    print("[o2micro-patch] done")
    print("[o2micro-patch] first test build is READ-ONLY, single-block, 1-bit, PIO")


if __name__ == "__main__":
    main()
