# eMachines D640 hardware snapshot

This document is a sanitized summary of the physical Linux SysReport captured from the target eMachines D640. Machine serial numbers, MAC addresses, UUIDs and other per-device identifiers are intentionally omitted.

## CPU and firmware

- Model: eMachines D640
- BIOS: Phoenix Technologies LTD V1.06, 2010-05-10
- CPU: AMD Phenom II N930 Quad-Core, Family 10h / Champlain
- CPUID signature: `0x00100F53`
- 4 cores / 4 threads, nominal 2.0 GHz
- Long mode: yes
- SSE3: yes
- **SSSE3: no**
- SSE4a: yes
- SSE4.1/SSE4.2: no
- AVX: no

The missing SSSE3 bit is important for Snow Leopard. The target profile enables OpenCore `Kernel -> Quirks -> LegacyCommpage`, whose purpose includes compatibility with pre-SSSE3 userspace paths.

## Chipset and storage

- RS880 host bridge: `1022:9601`, subsystem `1025:0377`
- External graphics PCIe bridge: `1022:9603`, subsystem `1025:0377`
- Southbridge SATA AHCI: `1002:4391`, subsystem `1025:0377`
- SMBus: `1002:4385`
- LPC: `1002:439D`
- Internal drive observed: WDC WD2500BEVT

Linux reports the SATA controller in AHCI mode, so the normal profile keeps broad SATA injector kexts disabled unless native attachment fails during macOS bring-up.

## Graphics

- GPU: AMD/ATI Park / Mobility Radeon HD 5430/5450/5470
- PCI ID: `1002:68E0`
- Subsystem: `1025:0377`
- VRAM: 512 MB DDR3, 64-bit
- Captured VBIOS size: 60928 bytes
- VBIOS SHA-256: `2d1c4738794a2616184ca1e281ac113ac8a411bdb80b658042dc78717093c170`
- VBIOS strings: `BR35968.V06`, `PARK`, `Acer JE40-DN PARK M2 XT DDR3 64Mx16 512MB`, `ATOMBIOSBK-ATI VER012.020.000.025.035968`

Confirmed connector topology from the Radeon driver and ATOM BIOS:

| Connector | Encoder | ATOM I2C ID | OS X sense ID |
|---|---|---:|---:|
| LVDS-1 | INTERNAL_UNIPHY | `0x96` | 7 |
| HDMI-A-1 | INTERNAL_UNIPHY1 | `0x91` | 2 |
| VGA-1 | INTERNAL_KLDSCP_DAC1 | `0x90` | 1 |

The internal panel runs at 1366x768. Linux did not return usable EDID bytes during this capture, therefore the exact LCD manufacturer/model is deliberately not asserted by the target profile.

A historical HD 5470 Hoolock personality patch exists for Acer/Park hardware with the same 7/2/1 connector sense map. It is a strong candidate, not proof for this machine. Automatic framebuffer patching stays disabled until the exact Snow Leopard ATI binary and patch pattern are verified.

## Audio

Internal codec:

- Realtek ALC272X
- Codec vendor ID: `0x10EC0272`
- Codec subsystem ID: `0x10250377`
- HDA controller: `1002:4383`, subsystem `1025:0377`
- Speaker pin: `0x14`
- Headphone pin: `0x21`
- External microphone: `0x18`
- Internal microphone: `0x19`

HDMI audio:

- PCI function: `1002:AA68`, subsystem `1025:0377`
- Codec: ATI R6xx HDMI, vendor ID `0x1002AA01`

VoodooHDA remains the conservative optional bring-up path. AppleHDA patching should be treated as a later, hardware-specific refinement.

## Network

- Ethernet: Broadcom BCM57780 Gigabit Ethernet, `14E4:1692`, subsystem `1025:033D`
- Wi-Fi: Qualcomm Atheros AR9285, `168C:002B`, subsystem `105B:E035`

The earlier AR9285 guess is therefore confirmed. Device-specific legacy macOS network enablement remains opt-in until the Snow Leopard kext version is selected and its matching ID table is verified.

## Input

- Keyboard: i8042 / AT Translated Set 2 keyboard
- Touchpad: SynPS/2 Synaptics TouchPad
- Touchpad firmware: 7.4
- Synaptics ID: `0x1C0B1`

This validates the existing VoodooPS2-based first-boot path.

## ACPI

The firmware exposes a single MADT/APIC table, not the duplicate-MADT condition seen on the Aspire 4310 profile.

- APIC length: 122 bytes
- OEM ID: `PTLTD`
- Firmware checksum byte: `0xDF`
- The captured table checksum is invalid
- Corrected checksum byte calculated from the captured 122-byte table: `0xE2`

Linux logs the firmware warning and continues. First-boot policy therefore keeps the original MADT and does **not** drop or replace it. A corrected table should only be introduced if the macOS/AMD kernel actually demonstrates an ACPI/APIC failure attributable to the checksum.

Observed firmware namespace also includes the embedded controller under `\_SB.PCI0.LPC0.EC0`, the Radeon device behind the external graphics bridge, and standard USB/LID wake objects.

## First-boot implications

The current conservative profile is:

- IA32 OpenDuet/OpenCore on legacy BIOS
- i386 Snow Leopard path
- user-supplied AMD K10-compatible `mach_kernel`
- `KernelCache=Cacheless` so the replacement `/mach_kernel` is used directly during bring-up
- `LegacyCommpage=YES` because the N930 lacks SSSE3
- `ProvideCurrentCpuInfo=NO` initially to avoid adding another variable before first hardware boot
- native AHCI first; broad SATA injectors only as fallback
- VoodooPS2 minimal input stack
- GPU framebuffer, Wi-Fi ID and ALC272 patches remain opt-in until their exact Snow Leopard binaries are verified
