# ASUS Eee PC 1215P physical hardware audit

Sanitized findings from the physical ASUS Eee PC 1215P Linux SysReport captured on 2026-09-15. The raw archive is intentionally not committed because it contains machine-specific identifiers.

## Confirmed platform

- Model: ASUS Eee PC 1215P
- BIOS: American Megatrends `0601`, DMI release date 2011-04-18
- CPU: Intel Atom N570, 2 cores / 4 threads, family 6 model 28 stepping 10, x86-64, SSE3, SSSE3, VT-x
- Memory: 2 GB DDR3-667 as two 1 GB DIMMs
- Chipset: Intel Pineview/NM10 + ICH7-family southbridge
- SATA: Intel `8086:27C1` in AHCI mode, 3 Gb/s
- Storage: Kingston A400 120 GB SATA SSD

## PCI devices

| Device | PCI ID | Subsystem | Notes |
| --- | --- | --- | --- |
| Host bridge | `8086:A010` | `1043:83AC` | Pineview/NM10 DMI bridge |
| GMA3150 VGA | `8086:A011` | `1043:8446` | primary iGPU function |
| GMA3150 display | `8086:A012` | `1043:8446` | secondary display function |
| HDA | `8086:27D8` | `1043:841C` | codec is ALC269VB |
| SATA AHCI | `8086:27C1` | `1043:83AD` | native AHCI candidate |
| SMBus | `8086:27DA` | `1043:83AD` | ICH7/NM10 SMBus |
| Ethernet | `1969:2062` | `1043:8468` | Atheros AR8152 v2, Linux `atl1c` |
| Wi-Fi | `168C:002B` | `105B:E035` | Atheros AR9285, Linux `ath9k` |

USB UHCI functions are `8086:27C8`, `27C9`, `27CA`, `27CB`; EHCI is `8086:27CC`.

## Display and VBIOS

Internal panel EDID identifies:

- manufacturer: HSD / HannStar
- model string: `HSD121PHW1`
- product code: `0x04B6`
- 1366x768 preferred timing
- physical size: 270 x 150 mm
- EDID manufacture week/year: week 42, 2011
- single-link LVDS is appropriate; `AAPL01,DualLink=00`

The captured 64 KiB Intel Pineview VBIOS reports:

```text
Intel(r) PineView PCI Accelerated SVGA BIOS
Build Number: 2001 PC 14.34  03/01/2010  02:34:31
```

VBIOS SHA-256:

```text
7d37003c8978d7c915e794c5eaab49c768072292e508ac1016b955d767edad5a
```

## Audio

Codec dump confirms **Realtek ALC269VB**:

- codec ID: `10EC:0269`
- subsystem: `1043:841C`
- internal speaker pin: `0x14`
- headphone pin: `0x21`
- external mic pin: `0x18`
- internal mic pin: `0x12`

For first Snow Leopard boot, audio stays optional. VoodooHDA is the conservative bring-up candidate; AppleHDA patching can be investigated after the base system is stable.

## Input

Keyboard:

- i8042 / PS2
- ACPI path `\_SB.PCI0.SBRG.PS2K`
- PNP IDs include `PNP0303` / `PNP030B`

Touchpad:

- Synaptics PS/2
- firmware 7.4
- IDs `SYN0A13`, `SYN0A00`, `SYN0002`, `PNP0F13`
- Linux reports max coordinates 5888 x 4728

The old Synaptics-compatible VoodooPS2 path is therefore the correct first target; Elantech support is not needed for this unit.

## Network

Ethernet is definitively **AR8152 v2 `1969:2062`**. Historical `AtherosL1cEthernet.kext` documentation explicitly lists `1969:2062` and Snow Leopard or newer, so it is the preferred wired-network candidate.

Wi-Fi is definitively **AR9285 `168C:002B`**, not BCM4313. Historical Snow Leopard reports show AR9285 working with patched/replaced Atheros IO80211-family components, including reports on 10.6.3. Do not replace Apple's IO80211 stack automatically until the exact period-correct binary and i386 compatibility are validated.

No Bluetooth controller enumerated in this capture.

## Webcam

Internal webcam is USB UVC:

```text
13D3:5711  IMC Networks USB 2.0 UVC VGA WebCam
```

This is a strong candidate for class-driver operation without a vendor-specific macOS kext, but that remains to be tested.

## ACPI / power

Important confirmed ACPI facts:

- DSDT OEM: `A1724 / A1724000`, 36,208 bytes
- PCI root: `\_SB.PCI0`
- raw AML explicitly defines `PCI0._UID = Zero`; the Snow Leopard legacy-GMA `_UID=0` workaround is therefore not required
- graphics ACPI device is `\_SB.PCI0.VGA`
- EC: `\_SB.PCI0.SBRG.EC0`, EC ports 0x62/0x66, GPE 0x1C
- keyboard: `PS2K`
- touchpad/mouse: `PS2M`
- battery: `BAT0`
- lid: `LID`
- legacy ASUS hotkey device: `ATKD`, HID `ASUS010`
- ACPI video exposes `_BCL` / `_BCM`; Linux has both `acpi_video0` and `intel_backlight`
- firmware reports S3, S4 and S5
- CPU power table: `PmRef CpuPm4` plus dynamically generated per-thread C/P-state SSDTs

The Linux boot used no explicit `acpi_osi=` override. Linux still detects both ASUS WMI and legacy ATKD interfaces and refuses the `eeepc_wmi` path while ATKD is active. macOS ACPI patches must therefore be based on this machine's tables, not a downloaded DSDT from another Eee PC.

## Battery

ACPI battery is functional under Linux:

- model: ASUS 1215P
- Li-ion
- design charge: 4400 mAh
- full charge reported: 4394 mAh in this capture

This makes legacy ACPI battery kexts plausible, but battery support stays post-first-boot.

## Card reader

No separate PCI or USB card-reader controller enumerated in this SysReport. The DSDT contains card-reader-related `KCRD` control methods associated with the southbridge/USB path, so the reader may be firmware/power/card-presence dependent.

Before selecting a macOS driver, repeat a small Linux check with an SD card physically inserted:

```bash
lspci -nnk
lsusb
lsblk -o NAME,PATH,TRAN,VENDOR,MODEL,SIZE,TYPE,FSTYPE
sudo dmesg | tail -200
```

## First macOS target

The hardware audit is sufficient to move from generic 1215P assumptions to a machine-specific Snow Leopard plan:

1. OpenCore Legacy / IA32.
2. Snow Leopard 10.6.3 retail-media path.
3. i386 kernelspace with Atom-capable kernel.
4. Intel AHCI `27C1` native first; injector only as fallback.
5. GMA3150 -> GMA950 spoof on `PciRoot(0x0)/Pci(0x2,0x0)` with the Dortania cursor patch.
6. `AAPL01,DualLink=00` for the confirmed 1366x768 HSD121PHW1 panel.
7. FakeSMC + PS/2 only for the minimal first boot.
8. Add AR8152 Ethernet next.
9. Add VoodooHDA/battery after a stable desktop.
10. Attempt AR9285 only after the base 10.6.3 system is stable.

Lion remains the second-stage target after Snow Leopard bring-up.
