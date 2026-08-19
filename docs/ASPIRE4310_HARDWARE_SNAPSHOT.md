# Physical Aspire 4310 hardware snapshot

This sanitized snapshot was collected from the target laptop under Linux on 2026-08-19.
Serial numbers, MAC addresses, disk UUIDs and raw firmware are intentionally not committed.
The private full report is stored locally under `input/hardware/`, which is ignored by Git.

## Platform

- Acer Aspire 4310, board name `Volvi`, BIOS V1.02 dated 2007-06-01.
- Intel Celeron M 520 at 1.60 GHz, CPUID family/model/stepping `6/15/6`, one core.
- 2 GiB DDR2 in two 1 GiB SODIMMs.
- Intel 945GM host bridge `8086:27a0`, ICH7-M LPC `8086:27b9`.
- Intel GMA950 `8086:27a2` plus auxiliary display function `8086:27a6`.
- Samsung `LTN141W1-L04` LVDS panel, 1280×800; its 128-byte EDID has a valid checksum.

## Storage and buses

- ICH7 IDE `8086:27df`, driven by Linux `ata_piix`.
- ICH7-M AHCI `8086:27c5`, driven by Linux `ahci`.
- Four ICH7 UHCI controllers and one EHCI controller.
- O2 Micro FireWire `1217:00f7`, SD `1217:7120`, and MS/xD `1217:7130`.

## Input

- Keyboard: `PNP0303`, AT Translated Set 2 on i8042 `serio0`, ports `0x60/0x64`, IRQ 1.
- Touchpad: Synaptics `SYN0302/SYN0300/SYN0002/PNP0f13`, i8042 `serio2`, IRQ 12.
- Linux detects an active i8042 multiplexing controller revision 1.1.
- Touchpad firmware is 6.5, hardware ID `0x81a0b1`, firmware ID `350306`.

These details make a controller/nub mismatch distinguishable from a missing ACPI device:
both keyboard and touchpad are exposed correctly by the firmware and work in Linux.

## Audio and communications

- ICH7 HDA controller `8086:27d8`, subsystem `1025:012f`.
- Realtek ALC268 codec `10ec:0268`, subsystem `1025:012b`.
- Secondary Conexant codec `14f1:2c06` (the modem function exposed on HDA).
- Broadcom BCM5787M Ethernet `14e4:1693`, subsystem `1025:011c`, Linux `tg3`.
- Broadcom BCM4311 802.11b/g `14e4:4311`, subsystem `1468:0422`, Linux `b43`.
- Broadcom BCM2045 Bluetooth USB `0a5c:2101`.
- Suyin/Acer CrystalEye UVC webcam `064e:a101`.

The LiveCD did not contain BCM4311 firmware, so its Linux Wi-Fi failure is not evidence of a
hardware fault. macOS runtime compatibility remains a separate test for every device.

## ACPI evidence

Every raw table was copied separately from sysfs. Its byte count matches the length in the
ACPI header, and every standard ACPI checksum is valid:

- DSDT: 30,197 bytes.
- FACP/FACS, HPET, MCFG, BOOT, TCPA and SLIC.
- Four SSDTs: CPU power/C-state/T-state tables and SATA AHCI support.
- APIC1: 104 bytes, OEM `INTEL/CALISTGA`.
- APIC2: 90 bytes, OEM `PTLTD/\t APIC`.

Linux reports the duplicate MADT as a BIOS bug and uses APIC1. That exactly matches the
OpenCore delete rule: retain `INTEL/CALISTGA`, remove only the 90-byte `PTLTD/\t APIC` table.
APIC1 describes IOAPIC ID 1 at `0xfec00000`, GSI 0–23, IRQ0→GSI2 and the level-triggered
IRQ9 override.

Other firmware facts useful for later patches:

- HPET at `0xfed00000`; PM timer at I/O `0x1008`.
- EC path `\_SB.PCI0.LPCB.EC0`, command/status `0x66`, data `0x62`, GPE `0x17`.
- Firmware exposes S0, S3, S4 and S5; Linux selects deep S3 sleep.
- `_OSC` returns `AE_NOT_FOUND`, so Linux disables ASPM.
- PMIO/GPIO SystemIO regions overlap ACPI OperationRegions; do not patch them without a
  concrete macOS failure.

The currently installed battery identifies as SANYO `AS07A31`, 11.1 V, 4.4 Ah design
capacity. Battery identity is replaceable hardware and is not used as a platform constant.

## Private artifact

Latest local archive:

```text
input/hardware/Aspire4310-Linux-SysReport-20260819-v3.tar.gz
SHA-256: f8e85a92830bb4e4d0577d3134bf9266ea8d9c892a2eac448006c2dc67c7227b
```

Recollect after a BIOS, mainboard, CPU, RAM, Wi-Fi card, panel or peripheral replacement:

```bash
./scripts/collect_linux_hardware.sh
```
