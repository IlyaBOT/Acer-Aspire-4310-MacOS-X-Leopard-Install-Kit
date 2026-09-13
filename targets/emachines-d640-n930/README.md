# eMachines D640 / Phenom II N930 target

This target is for the physical eMachines D640 described in the accompanying
`target.conf`.  It is intentionally conservative: it builds an IA32 OpenDuet /
OpenCore staging tree for Snow Leopard, but it does **not** claim that vanilla
Snow Leopard can boot on the AMD K10 CPU.

## Required before first real boot

A Snow Leopard-compatible legacy AMD kernel must be supplied by the user.  The
Linux USB writer installs that kernel as `/mach_kernel` on the installer volume
and preserves the retail kernel as `/mach_kernel.original` when present.

The repository does not download or redistribute a retail Snow Leopard image or
a third-party AMD kernel.

## Confirmed hardware

- AMD Phenom II N930 (K10/Champlain), CPUID `0x00100F53`, 4C/4T, 2.0 GHz.
- SSE/SSE2/SSE3/SSE4A; no SSE4.1/SSE4.2/AVX.
- AMD RS880M + SB800.
- ATI Mobility Radeon HD 5470 (Park), 512 MB, PCI `1002:68E0`.
- LG Philips LP140WH1-TLA2 1366x768 panel.
- Realtek ALC272 + ATI HDMI audio.
- Atheros AR5B95 wireless (AR9285/`168C:002B` is expected but should be
  confirmed from the Linux dump).
- Phoenix V1.06 legacy BIOS.

## Deliberately not automated yet

- HD 5470 framebuffer/connector patching.  The VBIOS, subsystem IDs and EDID
  must be captured first.  A generic `Eulemur` patch is not applied blindly.
- AR9285 `IO80211Family` edits.  Exact PCI/subsystem IDs must be confirmed first.
- DSDT patches.  No Acer-specific MADT deletion is inherited by this target.
- AppleHDA patching for ALC272.

## Bring-up order

1. Collect a fresh Linux hardware report with `scripts/collect_linux_hardware_v2.sh`.
2. Prepare project downloads with the existing `--download` flow.
3. Build the D640 EFI with `scripts/prepare_emachines_d640_snowleopard.sh --build`.
4. Supply a known-good Snow Leopard AMD K10 kernel explicitly.
5. Create the USB with the experimental Linux writer and boot verbose.
6. Only after the installer boots, add GPU/Wi-Fi/audio patches one subsystem at
   a time.
