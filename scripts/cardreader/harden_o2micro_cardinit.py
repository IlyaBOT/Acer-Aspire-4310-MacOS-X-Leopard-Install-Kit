#!/usr/bin/env python3
from pathlib import Path
import re
import sys


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        print(f"[o2micro-hardener] ERROR: {label}: expected 1 match, found {count}", file=sys.stderr)
        raise SystemExit(1)
    path.write_text(text.replace(old, new, 1))
    print(f"[o2micro-hardener] {label}")


def regex_replace_once(path: Path, pattern: str, replacement: str, label: str) -> None:
    text = path.read_text()
    # Pass the replacement through a callback so regex replacement syntax cannot
    # reinterpret escape sequences embedded in generated C/C++ source.
    new_text, count = re.subn(pattern, lambda _match: replacement, text, count=1, flags=re.S)
    if count != 1:
        print(f"[o2micro-hardener] ERROR: {label}: expected 1 match, found {count}", file=sys.stderr)
        raise SystemExit(1)
    path.write_text(new_text)
    print(f"[o2micro-hardener] {label}")


def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/VoodooSDHCI", file=sys.stderr)
        raise SystemExit(2)

    cpp = Path(sys.argv[1]).resolve() / "VoodooSDHC.cpp"
    if not cpp.is_file():
        print(f"[o2micro-hardener] ERROR: missing {cpp}", file=sys.stderr)
        raise SystemExit(1)

    # The first diagnostic patch bounded SDCommand(), but still used the old
    # driver's idea of command completion: ComInhibitCMD becoming clear.  That
    # is only a pre-command inhibit/state bit, not the completion indication.
    # A FULL_RESET also clears the interrupt-status-enable registers, so polling
    # NormalIntStatus without restoring those enables can leave NIS at zero.
    # Poll the SDHCI Command Complete / Error status bits exactly as the generic
    # SDHCI state machine expects, and consume the completion bit before return.
    sdcommand_fn = r'''bool VoodooSDHC::SDCommand(UInt8 slot, UInt8 command, UInt16 response,
								UInt32 arg) {
	bool busyResponse = (response == R1b || response == R5b);

	/* Every normal command requires CMD inhibit to be clear before issue.
	 * Busy responses additionally use DAT0, so do not start them while the
	 * data line is already inhibited. */
	UInt32 waited = 0;
	while (this->PCIRegP[slot]->PresentState & ComInhibitCMD) {
		if (waited >= SDHCI_CMD_TIMEOUT_US) {
			IOLog("VoodooSDHCI/O2: timeout BEFORE CMD%u waiting CMD inhibit PS=0x%08x NIS=0x%04x EIS=0x%04x\n",
				command,
				this->PCIRegP[slot]->PresentState,
				this->PCIRegP[slot]->NormalIntStatus,
				this->PCIRegP[slot]->ErrorIntStatus);
			Reset(slot, CMD_RESET);
			return false;
		}
		IODelay(SDHCI_POLL_STEP_US);
		waited += SDHCI_POLL_STEP_US;
	}

	if (busyResponse) {
		waited = 0;
		while (this->PCIRegP[slot]->PresentState & ComInhibitDAT) {
			if (waited >= SDHCI_CMD_TIMEOUT_US) {
				IOLog("VoodooSDHCI/O2: timeout BEFORE CMD%u waiting DAT inhibit PS=0x%08x NIS=0x%04x EIS=0x%04x\n",
					command,
					this->PCIRegP[slot]->PresentState,
					this->PCIRegP[slot]->NormalIntStatus,
					this->PCIRegP[slot]->ErrorIntStatus);
				Reset(slot, DAT_RESET);
				return false;
			}
			IODelay(SDHCI_POLL_STEP_US);
			waited += SDHCI_POLL_STEP_US;
		}
	}

	switch(response) { // SD Host Controller Spec 2.00 command response flags
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

	/* FULL_RESET clears these registers.  Status-enable controls whether the
	 * corresponding status bits are latched at all; signal-enable is deliberately
	 * left alone because this diagnostic path polls instead of depending on IRQs. */
	this->PCIRegP[slot]->NormalIntStatusEn |= (CmdComplete | ErrorInterrupt);
	this->PCIRegP[slot]->ErrorIntStatusEn = 0xffff;

	/* SDHCI status is write-one-to-clear. */
	this->PCIRegP[slot]->NormalIntStatus = (CmdComplete | ErrorInterrupt);
	this->PCIRegP[slot]->ErrorIntStatus = 0xffff;
	::OSSynchronizeIO();

#ifdef __DEBUG__
	IOLog("VoodooSDHCI/O2: -> CMD%u arg=0x%08x PS=0x%08x CLK=0x%04x PWR=0x%02x NEN=0x%04x EEN=0x%04x\n",
		command, arg,
		this->PCIRegP[slot]->PresentState,
		this->PCIRegP[slot]->ClockControl,
		this->PCIRegP[slot]->PowerControl,
		this->PCIRegP[slot]->NormalIntStatusEn,
		this->PCIRegP[slot]->ErrorIntStatusEn);
#endif

	this->PCIRegP[slot]->Command = (command << 8) | response;
	::OSSynchronizeIO();

	for (waited = 0; waited < SDHCI_CMD_TIMEOUT_US; waited += SDHCI_POLL_STEP_US) {
		UInt32 ps = this->PCIRegP[slot]->PresentState;
		UInt16 nis = this->PCIRegP[slot]->NormalIntStatus;
		UInt16 eis = this->PCIRegP[slot]->ErrorIntStatus;

		if ((nis & ErrorInterrupt) || eis) {
			IOLog("VoodooSDHCI/O2: error CMD%u arg=0x%08x PS=0x%08x NIS=0x%04x EIS=0x%04x RESP0=0x%08x\n",
				command, arg, ps, nis, eis, this->PCIRegP[slot]->Response[0]);
			this->PCIRegP[slot]->NormalIntStatus = (CmdComplete | ErrorInterrupt);
			this->PCIRegP[slot]->ErrorIntStatus = 0xffff;
			::OSSynchronizeIO();
			Reset(slot, CMD_RESET);
			if (busyResponse)
				Reset(slot, DAT_RESET);
			return false;
		}

		if (nis & CmdComplete) {
			UInt32 resp0 = this->PCIRegP[slot]->Response[0];
			this->PCIRegP[slot]->NormalIntStatus = CmdComplete;
			::OSSynchronizeIO();

			if (busyResponse) {
				UInt32 busyWaited = 0;
				while (this->PCIRegP[slot]->PresentState & ComInhibitDAT) {
					UInt16 busyNis = this->PCIRegP[slot]->NormalIntStatus;
					UInt16 busyEis = this->PCIRegP[slot]->ErrorIntStatus;
					if ((busyNis & ErrorInterrupt) || busyEis) {
						IOLog("VoodooSDHCI/O2: busy-response error CMD%u PS=0x%08x NIS=0x%04x EIS=0x%04x\n",
							command,
							this->PCIRegP[slot]->PresentState,
							busyNis, busyEis);
						Reset(slot, DAT_RESET);
						return false;
					}
					if (busyWaited >= SDHCI_CMD_TIMEOUT_US) {
						IOLog("VoodooSDHCI/O2: busy-response timeout CMD%u PS=0x%08x\n",
							command, this->PCIRegP[slot]->PresentState);
						Reset(slot, DAT_RESET);
						return false;
					}
					IODelay(SDHCI_POLL_STEP_US);
					busyWaited += SDHCI_POLL_STEP_US;
				}
			}

#ifdef __DEBUG__
			IOLog("VoodooSDHCI/O2: <- CMD%u complete RESP0=0x%08x NIS=0x%04x PS=0x%08x\n",
				command, resp0, nis, this->PCIRegP[slot]->PresentState);
#endif
			return true;
		}

		IODelay(SDHCI_POLL_STEP_US);
	}

	IOLog("VoodooSDHCI/O2: timeout AFTER CMD%u arg=0x%08x PresentState=0x%08x NIS=0x%04x EIS=0x%04x RESP0=0x%08x CLK=0x%04x PWR=0x%02x\n",
		command, arg,
		this->PCIRegP[slot]->PresentState,
		this->PCIRegP[slot]->NormalIntStatus,
		this->PCIRegP[slot]->ErrorIntStatus,
		this->PCIRegP[slot]->Response[0],
		this->PCIRegP[slot]->ClockControl,
		this->PCIRegP[slot]->PowerControl);
	dumpRegs(slot);
	Reset(slot, CMD_RESET);
	if (busyResponse)
		Reset(slot, DAT_RESET);
	return false;
}'''
    regex_replace_once(
        cpp,
        r"bool VoodooSDHC::SDCommand\(UInt8 slot, UInt8 command, UInt16 response,\n\s*UInt32 arg\) \{.*?\n\}\n\n/\*\n \* calcClock:",
        sdcommand_fn + "\n\n/*\n * calcClock:",
        "wait for SDHCI Command Complete instead of ComInhibitCMD",
    )

    # Program the SDHCI v1/v2 divider before enabling the internal clock.  The
    # upstream mask was 0xFF000 even though ClockControl is 16-bit; that happens
    # to encode /128 correctly, but destroys /2,/4,/8,/16 and would run the card
    # at 50 MHz when cardInit asks for 25 MHz.
    calcclock_fn = r'''bool VoodooSDHC::calcClock(UInt8 slot, UInt32 clockspeed) {
	UInt32 baseClock = ((this->PCIRegP[slot]->Capabilities[0] & 0x3F00) >> 8) * 1000000;
	if (baseClock == 0 || clockspeed == 0) {
		IOLog("VoodooSDHCI/O2: invalid clock request base=%u target=%u caps=0x%08x\n",
			baseClock, clockspeed, this->PCIRegP[slot]->Capabilities[0]);
		return false;
	}

	UInt32 div = 1;
	while ((baseClock / div) > clockspeed && div < 256)
		div <<= 1;
	if (div > 256)
		div = 256;

	/* SDHCI 1.0/2.0 stores divisor/2 in ClockControl[15:8]; zero means /1. */
	UInt16 encodedDiv = (div > 1) ? (UInt16)((div >> 1) << 8) : 0;

	this->PCIRegP[slot]->ClockControl = 0;
	::OSSynchronizeIO();
	IODelay(10);

	this->PCIRegP[slot]->ClockControl = encodedDiv | InternalClockEn;
	::OSSynchronizeIO();

	for (UInt32 waited = 0; waited < SDHCI_CLOCK_TIMEOUT_US; waited += SDHCI_POLL_STEP_US) {
		if (this->PCIRegP[slot]->ClockControl & SDClockStable) {
			this->PCIRegP[slot]->ClockControl = encodedDiv | InternalClockEn | SDClockEn;
			::OSSynchronizeIO();
			IODelay(10);
			IOLog("VoodooSDHCI/O2: BaseClock=%uMHz HostControllerVer=0x%04x Caps=0x%08x\n",
				baseClock / 1000000,
				this->PCIRegP[slot]->HostControllerVer,
				this->PCIRegP[slot]->Capabilities[0]);
			IOLog("VoodooSDHCI/O2: SD Clock=%uKHz divider=%u ClockControl=0x%04x\n",
				(baseClock / div) / 1000, div, this->PCIRegP[slot]->ClockControl);
			return true;
		}
		IODelay(SDHCI_POLL_STEP_US);
	}

	IOLog("VoodooSDHCI/O2: internal clock did not become stable target=%u divider=%u ClockControl=0x%04x\n",
		clockspeed, div, this->PCIRegP[slot]->ClockControl);
	dumpRegs(slot);
	this->PCIRegP[slot]->ClockControl = 0;
	::OSSynchronizeIO();
	return false;
}'''
    regex_replace_once(
        cpp,
        r"bool VoodooSDHC::calcClock\(UInt8 slot, UInt32 clockspeed\) \{.*?\n\}\n\n/\*\n \* powerSD:",
        calcclock_fn + "\n\n/*\n * powerSD:",
        "fix 16-bit SDHCI clock divider programming/order",
    )

    # Power must be stable before the card clock and the initial 74+ clock cycles.
    # The old driver did this in the opposite order.  Ten milliseconds is
    # intentionally conservative for this diagnostic build.
    power_fn = r'''bool VoodooSDHC::powerSD(UInt8 slot) {
	UInt8 voltage = 0;
	UInt32 caps = this->PCIRegP[slot]->Capabilities[0];

	if (caps & CR3v3Support)
		voltage = HC3v3;
	else if (caps & CR3v0Support)
		voltage = HC3v0;
	else if (caps & CR1v8Support)
		voltage = HC1v8;
	else {
		IOLog("VoodooSDHCI/O2: no supported SD bus voltage caps=0x%08x\n", caps);
		return false;
	}

	this->PCIRegP[slot]->PowerControl = 0;
	::OSSynchronizeIO();
	IODelay(1000);
	this->PCIRegP[slot]->PowerControl = voltage | SDPower;
	::OSSynchronizeIO();
	IODelay(10000);

	IOLog("VoodooSDHCI/O2: power on PowerControl=0x%02x caps=0x%08x\n",
		this->PCIRegP[slot]->PowerControl, caps);
	return true;
}'''
    regex_replace_once(
        cpp,
        r"bool VoodooSDHC::powerSD\(UInt8 slot\) \{.*?\n\}\n\n/\*\n \* parseCID:",
        power_fn + "\n\n/*\n * parseCID:",
        "power card before enabling SD clock",
    )

    replace_once(
        cpp,
        "\tisHighCapacity = false;\n\tif (!calcClock(slot, 400000))\n\t\treturn false;\n\tpowerSD(slot);\n\tif (!SDCommand(slot, SD_GO_IDLE_STATE, SDCR0, 0))",
        "\tisHighCapacity = false;\n\tif (!powerSD(slot))\n\t\treturn false;\n\tif (!calcClock(slot, 400000))\n\t\treturn false;\n\t/* 1 ms at ~390 kHz supplies far more than the required 74 startup clocks. */\n\tIODelay(1000);\n\tif (!SDCommand(slot, SD_GO_IDLE_STATE, SDCR0, 0))",
        "sequence power -> 400kHz clock -> CMD0",
    )

    # Keep every mandatory command in the remainder of cardInit fail-fast.
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

    print("[o2micro-hardener] SDHCI command completion, clocking, power sequencing, and cardInit checks hardened")


if __name__ == "__main__":
    main()
