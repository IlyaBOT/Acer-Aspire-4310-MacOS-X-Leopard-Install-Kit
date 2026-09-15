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

The profile hierarchy records `INSTALL_METHOD=online-recovery` for these systems now, but profiles remain `planned` until the target-specific kernel, graphics and kext path has been hardware-validated. The dispatcher will allow `--doctor` for a planned profile but refuses build/destructive operations instead of creating misleading media.

## Legacy BIOS USB probe

`scripts/d640_usb_boot_probe.sh` remains a standalone destructive diagnostic tool. It tests BIOS -> MBR -> PBR behavior using tiny marker boot sectors and intentionally does not boot macOS.

The generic dispatcher exposes it only when explicitly requested:

```bash
./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe --list
sudo ./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe \
  --disk /dev/sdX --case mbr-direct
```

It is intentionally **not** run automatically by `--make-usb`: a BIOS probe destroys/reformats the target media and belongs to troubleshooting, not the normal install path.
