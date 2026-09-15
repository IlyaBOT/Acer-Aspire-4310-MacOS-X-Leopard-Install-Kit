# ASUS Eee PC 1215P macOS bring-up notes

This target is intentionally **planned / pre-audit**. Public information is good enough to prepare the profile, but ASUS shipped component variants and the physical machine must be inventoried before we enable the build/media engine.

## Bring-up order

1. Boot Linux and collect a private full SysReport.
2. Reconcile PCI/USB IDs, DMI, DSDT/SSDT, EDID, audio codec, touchpad and Wi-Fi against this profile.
3. First macOS target: **Snow Leopard 10.6.3**, i386 kernelspace, custom Atom kernel.
4. Stabilize storage, PS/2, display, Ethernet and power/battery one subsystem at a time.
5. Only after a known-good 10.6.3 boot, stage later Snow Leopard updates deliberately; historical 1215P reports specifically describe a broken system after an unprepared 10.6.8 update.
6. Second macOS target: **Lion 10.7.x**, using OpenCore online Recovery and an Atom-capable Lion kernel.

## Linux audit command

From the repository root:

```bash
sudo ./scripts/collect_linux_hardware_v2.sh "$PWD/input/hardware" asus-eee-pc-1215p
```

The resulting `*.tar.gz` is private by design and may contain serial numbers, MAC addresses and firmware identifiers. Do not commit it; share it privately for analysis and commit only sanitized facts.

## Hardware baseline from public reports

Common/observed 1215P configuration:

- Intel Atom N570, Pineview/Bonnell, 2 cores / 4 threads, family 6 model 28 stepping 10.
- Intel N10/NM10 platform.
- GMA3150 functions `8086:A011` + `8086:A012`.
- Intel AHCI controller `8086:27C1`.
- Intel HDA `8086:27D8`, commonly Realtek ALC269 (`10EC:0269`).
- Atheros AR8152 v2 Fast Ethernet `1969:2062` is documented on real 1215P units.
- Wi-Fi varies: BCM4313 (`14E4:4727`), AR9285 (`168C:002B`) and Ralink-family options all appear in ASUS/public records.
- 1366x768 internal panel; one real 1215P report identifies HannStar HSD121PHW1/HSD04B6.
- Synaptics and Elantech touchpad evidence both exist, so the physical unit decides the driver path.
- 3-in-1/4-in-1 SD-family reader exists, but the controller ID must come from the audit.
- ASUS BIOS 0601 (2011-05-11) is the latest official 1215P BIOS located during research. AHCI must be enabled.

## Snow Leopard historical evidence

An archived Russian Eee PC forum link is referenced from old community mirrors. The exact Wayback page is not reliably fetchable through automated tools, but indexed mirrors preserve a 1215P success report from February 2012:

- Snow Leopard 10.6.3 installed on ASUS 1215P.
- Chameleon v2 RC5.
- modified Atom kernel.
- AHCI SATA enabled in BIOS and selected in installer.
- FakeSMC / Disabler-era boot stack.
- VoodooHDA, PS/2 and battery kexts.
- Ethernet brought up using AtherosL1cEthernet.kext.
- Wi-Fi and Fn shortcuts were reported not working in the initial setup.
- author later reported that an unprepared 10.6.8 update broke the installation.

We treat this only as **proof that the platform can reach a usable 10.6.3 system**, not as a package list to reproduce. The new approach should use OpenCore and the smallest possible legacy kext set.

## GMA3150 strategy

Dortania's Legacy Intel Setup explicitly lists GMA3150 as partially supportable through the GMA950 path, while warning that proper acceleration is missing. The target therefore forces an i386 kernelspace and records:

- expected iGPU PCI path `PciRoot(0x0)/Pci(0x2,0x0)`;
- fake GMA950 device-id `A2270000` (`0x27A2` little-endian);
- laptop panel properties;
- `AAPL01,DualLink=00` for 1366x768;
- AppleIntelIntegratedFramebuffer cursor-corruption binary patch for Darwin 8 through 11.

See `../gma3150.conf` for the exact profile values.

The cursor patch does **not** create QE/CI or full acceleration; framebuffer behavior, native resolution, corruption and application compatibility must all be tested on the machine.

## Network strategy

### Ethernet

If Linux confirms `1969:2062`, AtherosL1cEthernet.kext is a strong candidate: historical driver documentation explicitly lists AR8152 `2062` and Snow Leopard or newer.

### Wi-Fi

Do not commit to a Wi-Fi solution until the physical card ID is known.

- AR9285 `168C:002B`: historical Snow Leopard support exists, with stronger reports from 10.6.5 onward and older IO80211 replacement/injection methods.
- BCM4313 `14E4:4727`: do not assume native support.
- Ralink: exact chip must be identified before deciding whether any period-correct OS X driver is viable.

For the first 10.6.3 boot, Wi-Fi should remain optional/offline; wired Ethernet is the preferred network path.

## ACPI / power / input

Linux documentation for 1215P/Eee PC generation reports `_OSI`-dependent ASUS WMI/legacy ATKD behavior and hotkey/backlight differences. Do not import random DSDTs from another Eee PC. We need the physical DSDT/SSDT set and should inspect at least:

- PCI root `_UID` (Snow Leopard legacy Intel graphics is sensitive to bad PCI-root identity);
- EC/battery methods;
- lid/sleep devices;
- GFX0/IGD naming and backlight devices;
- PS/2 controller and touchpad identity;
- ASUS WMI/ATKD devices and Fn hotkeys;
- HPET/RTC/PIC interrupt resources.

## Sources used for the pre-audit profile

- ASUS 1215P support/download pages: https://www.asus.com/us/supportonly/eee%20pc%201215p/helpdesk_download/
- ASUS 1215P BIOS page: https://www.asus.com/us/supportonly/eee%20pc%201215p/helpdesk_bios/
- Debian Eee PC 1215P hardware notes: https://wiki.debian.org/DebianEeePC/Model/1215P
- Dortania Legacy Intel Setup: https://dortania.github.io/OpenCore-Post-Install/gpu-patching/legacy-intel/
- InsanelyMac 1215P/Lion discussion: https://www.insanelymac.com/forum/topic/270958-aiuto-lion-su-asus-1215p/
- InsanelyMac AR9285 Snow Leopard discussion: https://www.insanelymac.com/forum/topic/190289-solved-ar9285-asus-eee-1008ha-and-snow-leopard/
- AtherosL1cEthernet controller list: https://www.insanelymac.com/forum/files/file/374-atherosl1cethernetkext/
- Historical page supplied for research: https://web.archive.org/web/20180711100555/http://www.eee-pc.ru/forum/read/87/19208

## Unknown until our physical audit

- exact BIOS revision and settings;
- exact RAM technology/SPD layout on this unit;
- Wi-Fi and Bluetooth IDs;
- touchpad controller/protocol;
- card-reader controller;
- internal panel EDID;
- webcam USB ID;
- full DSDT/SSDT namespace;
- ALC269 codec node layout;
- whether GMA3150 gets stable native 1366x768 framebuffer and what level of acceleration, if any, is usable;
- sleep/wake, brightness and Fn-key behavior under macOS.
