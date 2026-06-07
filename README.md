# Acer Aspire 4310 Leopard USB Kit

This kit prepares the files and commands needed to build a bootable Mac OS X Leopard USB installer for an Acer Aspire 4310 using Chameleon and legacy kexts.

The destructive USB creation path is intentionally guarded. The script shows `diskutil info`, checks for an external/removable USB disk, and refuses to erase anything until you type the exact confirmation string:

```bash
ERASE /dev/diskX
```

## Legal source requirement

The script does not download a Mac OS X Leopard retail installer ISO/DMG. Apple still hosts some updates, but not a retail Leopard installer download for this workflow. Use your own legally obtained retail DVD or disk image and pass it with `--retail`.

Unofficial archive downloads are deliberately not automated here.

## Project layout

```text
acer4310-leopard-kit/
  README.md
  prepare_acer4310_leopard_usb.sh
  downloads/
  input/
  work/
  logs/
  output/
```

`downloads/` stores downloaded archives and DMGs. `input/` is a convenient place for your retail Leopard image. `work/` stores extracted tools. `output/` stores generated `/Extra`, optional injectors, next-step notes, and HDD command scripts.

## What download-only fetches

```bash
./prepare_acer4310_leopard_usb.sh --download-only
```

This mode:

- downloads the official Apple Mac OS X 10.5.8 Combo Update from Apple Support/CDN
- tries to locate the old 10.5.6 Combo Update only from official Apple URLs, but skips it if Apple no longer exposes a DMG
- downloads Legacy-Kexts from GitHub
- tries to download Chameleon 2.2 r2404 binaries from the historical Chameleon URL
- extracts archives into `work/`
- builds `output/Extra`
- writes `output/README_NEXT_STEPS.txt`

If the Chameleon URL is unavailable, manually place an archive containing `i386/boot0`, `i386/boot1h`, and `i386/boot` at:

```text
downloads/chameleon-binaries.tar.gz
```

Then rerun `--download-only`.

## List disks

Run this only on macOS:

```bash
./prepare_acer4310_leopard_usb.sh --list-disks
```

It runs:

```bash
diskutil list
```

Use the whole-disk identifier for the USB drive, for example `/dev/disk2`, not a slice such as `/dev/disk2s1`.

## Create the USB

Run this only on macOS after `--download-only` has prepared the tools:

```bash
./prepare_acer4310_leopard_usb.sh --make-usb --disk /dev/diskX --retail /path/to/Leopard.dmg
```

Other supported retail sources:

```bash
./prepare_acer4310_leopard_usb.sh --make-usb --disk /dev/diskX --retail /path/to/Leopard.iso
./prepare_acer4310_leopard_usb.sh --make-usb --disk /dev/diskX --retail "/Volumes/Mac OS X Install DVD"
```

The USB is partitioned as MBR:

```text
partition 1: JHFS+ CHAMUSB 512M
partition 2: JHFS+ LEOPARD 9G
partition 3: JHFS+ TOOLS remaining space
```

The script restores the retail installer to the `LEOPARD` partition with `asr restore`, installs Chameleon boot files on `CHAMUSB`, copies `/Extra`, and places updates/tools/notes on `TOOLS`.

## Included default kexts

Copied to `CHAMUSB/Extra/Extensions` from Legacy-Kexts:

- `FakeSMC.kext`
- `NullCPUPowerManagement.kext`
- `VoodooPS2.kext`, or the current archive name `VoodooPS2Controller.kext`
- `AppleACPIPS2Nub.kext`
- `EvOreboot.kext`
- `VoodooHDA.kext`
- `ACPIBatteryManager.kext`/`AppleACPIBatteryManager.kext`, or `VoodooBattery.kext` if ACPIBatteryManager is absent

SATA injectors are not enabled by default. These are copied to `TOOLS/Optional-Injectors` for manual use if you hit `Still waiting for root device`:

- `AHCIPortInjector.kext`
- `ATAPortInjector.kext`
- `SATA-unsupported.kext`

## Install Chameleon to HDD after first boot

This mode is conservative. By default it generates commands only and does not execute them:

```bash
./prepare_acer4310_leopard_usb.sh --install-chameleon-hdd --target /Volumes/LeopardHD --disk /dev/disk0 --slice /dev/disk0s2
```

It writes:

```text
output/install_chameleon_hdd_commands.sh
```

Review that file on the running Leopard system before executing. If you explicitly want the script to run the generated commands, add `--execute`; it will still require an exact confirmation string.

## Recreate or roll back

To recreate the USB, rerun `--make-usb` with the same disk identifier and confirm the erase again. To roll back a failed USB attempt, erase/repartition the USB from macOS Disk Utility or rerun this script with the correct USB disk.

No HDD Chameleon commands are run unless you execute the generated script yourself or pass `--execute` and confirm.

## Common boot issues

- `Still waiting for root device`: copy SATA/ATA injectors from `TOOLS/Optional-Injectors` to `CHAMUSB/Extra/Extensions`, then fix owner/perms.
- Hang at `AppleIntelCPUPowerManagement`: verify `NullCPUPowerManagement.kext`.
- Hang before `DSMOS`: verify `FakeSMC.kext`.
- No keyboard/touchpad: verify `VoodooPS2.kext` and `AppleACPIPS2Nub.kext`.
- No audio: start with `VoodooHDA.kext`; look for ALC268-specific AppleHDA/MadTux fixes later.
- No Ethernet: BCM5787M is not required for installation. Use Wi-Fi, USB Ethernet, or search for a compatible BCM5787M/AppleBCM5751Ethernet kext separately.

## Notes for Windows/Linux

`--download-only` can run from Bash on Windows/Linux if `curl` or `wget` is available. Disk preparation requires macOS because it uses `diskutil`, `hdiutil`, `asr`, `fdisk`, `dd`, and HFS+ volume handling.
