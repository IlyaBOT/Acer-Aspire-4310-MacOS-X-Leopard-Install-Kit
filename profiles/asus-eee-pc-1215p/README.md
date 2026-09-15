# ASUS Eee PC 1215P macOS bring-up notes

This target now has a **physical Linux hardware audit**. Raw SysReport data is intentionally kept out of Git because it contains machine-specific identifiers; sanitized findings are in [`AUDIT.md`](AUDIT.md).

## Bring-up order

1. First macOS target: **Snow Leopard 10.6.3**, OpenCore Legacy IA32, i386 kernelspace, Atom-capable kernel.
2. Boot with the smallest possible set: FakeSMC + PS/2, native Intel `27C1` AHCI first, audited GMA3150 framebuffer properties.
3. Stabilize display/input/storage before adding network/audio/battery.
4. Add confirmed AR8152 Ethernet using a period-correct AtherosL1cEthernet build.
5. Add ALC269VB audio and ACPI battery support after a stable desktop.
6. Attempt confirmed AR9285 Wi-Fi only after the base 10.6.3 system is stable.
7. Do **not** jump directly to 10.6.8; historical 1215P reports describe an unprepared update breaking the installation. Stage the later Atom kernel/update path first.
8. Second macOS target: **Lion 10.7.x**, online Recovery + Atom-capable Lion kernel, still with i386 kernelspace for legacy GMA.

## Confirmed physical machine

- Intel Atom N570, 2C/4T, family 6 model 28 stepping 10, x86-64 + SSSE3 + VT-x.
- 2 GB DDR3-667, two 1 GB DIMMs.
- Intel Pineview/NM10 + ICH7 family.
- Intel AHCI `8086:27C1`.
- Kingston A400 120 GB SATA SSD.
- GMA3150 `8086:A011/A012`, ASUS subsystem `1043:8446`.
- HannStar `HSD121PHW1` 1366x768 LVDS panel.
- Intel HDA `8086:27D8` + Realtek **ALC269VB `10EC:0269`**.
- Ethernet: **AR8152 v2 `1969:2062`**, subsystem `1043:8468`.
- Wi-Fi: **AR9285 `168C:002B`**, subsystem `105B:E035`.
- Touchpad: **Synaptics PS/2**, fw 7.4, `SYN0A13/SYN0A00/SYN0002`.
- Keyboard: i8042 PS/2.
- Webcam: IMC Networks USB UVC `13D3:5711`.
- BIOS: AMI `0601`, DMI release 2011-04-18.

The integrated card reader did not enumerate as a separate PCI/USB device in this capture. Recheck it with an SD card physically inserted before selecting a driver.

## GMA3150 strategy

Dortania's Legacy Intel Setup treats GMA3150 as partial support through the GMA950 path and explicitly warns that proper acceleration is missing. The physical target confirms the expected PCI path and a 1366x768 single-link LVDS panel, so the starting OpenCore graphics data is:

```text
PciRoot(0x0)/Pci(0x2,0x0)
ACPI device: \_SB.PCI0.VGA
native IDs: 8086:A011 / 8086:A012
fake device-id: A2270000    # GMA950 0x27A2
AAPL,HasPanel: 01000000
AAPL01,DualLink: 00
```

Physical panel EDID:

```text
HSD / HannStar HSD121PHW1
1366x768
product 0x04B6
270 x 150 mm
```

Use the known GMA3150 cursor-corruption patch:

```text
Identifier = com.apple.driver.AppleIntelIntegratedFramebuffer
Find       = 8b550883bab0000000017e36890424e832bbffff
Replace    = b800000002909090909090909090eb0400000000
MinKernel  = 8.0.0
MaxKernel  = 11.99.99
```

The physical 64 KiB VBIOS is Intel PineView Build `2001 PC 14.34` dated 2010-03-01; its SHA-256 is recorded in `gma3150.conf`.

Important: this patch fixes cursor corruption; it does **not** manufacture QE/CI or full GMA3150 acceleration.

## ACPI findings

Raw AML from this machine confirms:

- PCI root `\_SB.PCI0` has **`_UID = Zero` already**. The classic Snow Leopard GMA `_UID=0` fix should not be needed.
- graphics device: `\_SB.PCI0.VGA`;
- EC: `\_SB.PCI0.SBRG.EC0`, ports 0x62/0x66, GPE 0x1C;
- PS/2 keyboard/mouse devices: `PS2K` / `PS2M`;
- battery: `BAT0`;
- lid: `LID`;
- legacy ASUS hotkey device: `ATKD`, HID `ASUS010`;
- firmware also exposes ASUS WMI behavior;
- ACPI video contains `_BCL` / `_BCM` brightness controls;
- S3/S4/S5 are present;
- CPU PM table is `PmRef CpuPm4` with dynamic per-thread C/P-state SSDTs.

The Linux kernel command line in the audit had **no explicit `acpi_osi=` override**. Linux still detects both WMI and legacy ATKD interfaces, so macOS patches must be based on this machine's own AML rather than a random Eee PC DSDT.

The SysReport host did not have `iasl`, so raw DSDT/SSDT tables were captured but not decompiled. Before final ACPI patching, install ACPICA tools and rerun the collector or decompile the existing AML separately.

## Network strategy

### Ethernet

The physical NIC is exactly `1969:2062`. Historical AtherosL1cEthernet documentation lists AR8152 `1969:2062` and Snow Leopard or newer, making it the preferred wired-network candidate.

### Wi-Fi

The physical card is AR9285 `168C:002B`. Historical Snow Leopard reports show this card working using patched/replaced Atheros components in `IO80211Family`, including reports on 10.6.3. Do not automatically replace the Apple Wi-Fi stack until the exact binary's provenance and i386 support are checked.

For the very first boot, wired Ethernet is still preferable; Wi-Fi is optional.

## Audio / battery / webcam

- ALC269VB codec topology is captured; first candidate is VoodooHDA after base boot.
- ACPI `BAT0` is functional under Linux, so a legacy battery kext is plausible after base boot.
- Webcam `13D3:5711` is standard USB UVC and should be tested with Apple's class driver before adding anything vendor-specific.

## Snow Leopard historical evidence

Old ASUS 1215P community reports establish a useful baseline:

- Snow Leopard 10.6.3 booted on the platform;
- Chameleon RC5-era installs used a modified Atom kernel and AHCI;
- FakeSMC/PS2/VoodooHDA/battery-era kexts were used;
- Ethernet was brought up with AtherosL1cEthernet;
- Wi-Fi/Fn support varied;
- at least one user reported an unprepared 10.6.8 update breaking the installation.

We use this only as proof of feasibility, **not** as a package recipe. The new path is OpenCore Legacy with the smallest possible target-specific legacy stack.

## Sources

- Physical Linux SysReport, sanitized into [`AUDIT.md`](AUDIT.md)
- Dortania Legacy Intel Setup: https://dortania.github.io/OpenCore-Post-Install/gpu-patching/legacy-intel/
- Debian 1215P notes: https://wiki.debian.org/DebianEeePC/Model/1215P
- ASUS support: https://www.asus.com/us/supportonly/eee%20pc%201215p/helpdesk_download/
- InsanelyMac 1215P/Lion discussion: https://www.insanelymac.com/forum/topic/270958-aiuto-lion-su-asus-1215p/
- AR9285 Snow Leopard discussion: https://www.insanelymac.com/forum/topic/190289-solved-ar9285-asus-eee-1008ha-and-snow-leopard/
- AtherosL1cEthernet controller list: https://www.insanelymac.com/forum/files/file/374-atherosl1cethernetkext/
- Historical page supplied for research: https://web.archive.org/web/20180711100555/http://www.eee-pc.ru/forum/read/87/19208

## Remaining unknowns before first macOS boot

- exact Atom 10.6.3 kernel binary/provenance to package;
- final OpenCore IA32 config generated from this target profile;
- exact behavior of GMA3150 framebuffer/native resolution under OS X;
- integrated card-reader ID with media inserted;
- whether Bluetooth hardware is absent or merely disabled;
- macOS sleep/wake, brightness and Fn-key behavior.
