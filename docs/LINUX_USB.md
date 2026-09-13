# Linux USB deployment backend

This branch adds an **experimental** Linux path for creating and updating a
legacy OpenCore/OpenDuet USB. The boot-sector step intentionally delegates to
OpenCorePkg's own `Utilities/LegacyBoot/BootInstall_*.tool` rather than carrying
a private implementation of `boot0` / `boot1f32` writes.

Upstream OpenCore currently documents `Utilities/LegacyBoot` as supporting
Linux and macOS natively. Its Linux `BootInstallBase.sh` uses `lsblk`, `fdisk`,
`dd`, `mount -t vfat`, `boot0`, `boot1f32` and `boot{IA32,X64}`.

Source references:

- https://github.com/acidanthera/OpenCorePkg/tree/master/Utilities/LegacyBoot
- https://github.com/acidanthera/OpenCorePkg/blob/master/Utilities/LegacyBoot/BootInstallBase.sh

## What the Linux backend does

For `--make-usb` it:

1. rejects the Linux root disk and, by default, any disk that is not clearly
   removable or USB;
2. requires an exact `ERASE /dev/...` confirmation;
3. creates a GPT with a 200 MiB FAT32 EFI System Partition and an HFS+ installer
   partition;
4. mounts a user-provided retail ISO/raw image read-only, or converts a DMG with
   `dmg2img` before mounting it;
5. copies the installer filesystem to the new HFS+ volume;
6. optionally backs up `/mach_kernel` and replaces it with a user-supplied
   legacy AMD kernel;
7. copies the generated OpenCore EFI tree;
8. invokes OpenCorePkg's native Linux LegacyBoot installer;
9. performs a read-only verification pass.

`--update-efi` preserves the partition map and installer partition while
replacing only EFI/OpenDuet files and reinstalling the legacy boot sectors.

## Dependencies

Debian/Ubuntu package names vary by release, but the required commands are:

- `lsblk`, `findmnt`, `losetup`, `blkid`, `mount`, `umount` (`util-linux`)
- `sgdisk` (`gdisk`)
- `mkfs.vfat` (`dosfstools`)
- `mkfs.hfsplus` (`hfsprogs` or equivalent HFS+ tools)
- `rsync`
- `fdisk`
- `uuidgen`
- `dmg2img` for compressed DMGs

## Important limitation

The HFS+ **filesystem copy** performed from Linux is the least proven part of
this path. It preserves normal Unix ownership/modes/symlinks via `rsync -aH`,
but it is not presented as a byte-for-byte replacement for Apple's `asr`.
Always run `--verify` and treat the first boots as bring-up tests.

If a particular retail image depends on Apple-specific filesystem metadata not
preserved by the Linux HFS+ driver, use macOS/`asr` for the installer volume and
use Linux only for `--update-efi`/OpenDuet.
