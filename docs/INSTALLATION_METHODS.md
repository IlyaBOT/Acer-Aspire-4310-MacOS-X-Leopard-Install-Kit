# Installation methods

The project deliberately uses two installer-media models because early Mac OS X releases and Lion-era releases are best handled differently.

## Leopard / Snow Leopard: retail media

The existing pipeline keeps the current behavior:

1. inspect/provide the retail DVD/ISO;
2. build the OpenCore/OpenDuet tree and target kext set;
3. create or update the USB layout;
4. verify the resulting USB.

The proven Acer command stack is intentionally preserved behind the generic dispatcher.

## Lion and newer: OpenCore online Recovery

Future Lion, Mountain Lion and Mavericks profiles use OpenCore's recovery-image flow rather than pretending that the Leopard/Snow Leopard DVD restore path applies unchanged.

OpenCore documentation describes the simplest recovery installation as placing the recovery `.dmg` and `.chunklist` in:

```text
com.apple.recovery.boot/
```

on a FAT32 partition alongside OpenCore. OpenCore's `macrecovery.py` downloads the recovery pair. An HFS+ filesystem driver is required because the recovery image itself is HFS+.

References:

- https://dortania.github.io/docs/latest/Differences.html
- https://github.com/acidanthera/OpenCorePkg/tree/master/Utilities/macrecovery
- https://github.com/dortania/OpenCore-Install-Guide/blob/master/installer-guide/mac-install-recovery.md

The profile hierarchy records `INSTALL_METHOD=online-recovery` for these systems. Planned profiles remain doctor-only, but the experimental ASRock FM2A58M-VG3+ / A8-7600 Mavericks target now implements this flow end-to-end on Linux:

```bash
./legacy_macos_install.sh --target asrock-fm2a58m-vg3-a8-7600 --os mavericks --download
./legacy_macos_install.sh --target asrock-fm2a58m-vg3-a8-7600 --os mavericks --build
sudo ./legacy_macos_install.sh --target asrock-fm2a58m-vg3-a8-7600 --os mavericks \
  --make-usb --disk /dev/sdX
```

The A8 writer creates a GPT disk with one FAT32 EFI System Partition, copies the X64 UEFI OpenCore tree and `/Kernels/mach_kernel`, then runs the pinned OpenCore 1.0.5 `macrecovery.py` directly against the mounted USB. It requests Mavericks with board ID `Mac-F60DEB81FF30ACF6` and MLB `00000000000FNN100`, writing `RecoveryImage.dmg` and `RecoveryImage.chunklist` under `com.apple.recovery.boot/`.

This path is UEFI-only for normal bring-up. It uses `OpenHfsPlus.efi` rather than `HfsPlusLegacy.efi`; OpenDuet is not installed by `--make-usb` for this target.

## Legacy BIOS USB probe

`scripts/d640_usb_boot_probe.sh` remains a standalone destructive diagnostic tool. It tests BIOS -> MBR -> PBR behavior using tiny marker boot sectors and intentionally does not boot macOS.

The generic dispatcher exposes it only when explicitly requested:

```bash
./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe --list
sudo ./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe \
  --disk /dev/sdX --case mbr-direct
```

It is intentionally **not** run automatically by `--make-usb`: a BIOS probe destroys/reformats the target media and belongs to troubleshooting, not the normal install path.
