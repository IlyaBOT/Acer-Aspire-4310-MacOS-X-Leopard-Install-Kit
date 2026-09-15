# Weird Legacy Laptops macOS Install Kit

A profile-driven toolkit for building and troubleshooting macOS/OpenCore install media for old laptops whose firmware, CPU or device mix does not fit a normal modern Hackintosh recipe.

> Repository slug is still `Acer-Aspire-4310-MacOS-X-Leopard-Install-Kit` for compatibility. The project itself is now organized as a multi-laptop installer kit.

## Current targets

| Target | Leopard | Snow Leopard | Lion | Mountain Lion | Mavericks |
| --- | --- | --- | --- | --- | --- |
| Acer Aspire 4310 | supported | supported | planned | — | — |
| eMachines D640 / Phenom II N930 | — | experimental | planned | planned | planned |
| ASUS Eee PC 1215P / Atom N570 | — | planned (10.6.3 first) | planned | — | — |

`planned` means profile metadata and the correct installation architecture are defined, but the target-specific kernel/kext path has not been hardware-validated. The tool refuses destructive/build operations for those profiles instead of pretending they work.

## Recommended entry point

```bash
./legacy_macos_install.sh --list-targets
./legacy_macos_install.sh --list-profiles
```

Acer Aspire 4310 examples:

```bash
./legacy_macos_install.sh --target acer-aspire-4310 --os leopard --doctor
./legacy_macos_install.sh --target acer-aspire-4310 --os snowleopard --download
./legacy_macos_install.sh --target acer-aspire-4310 --os snowleopard --build
./legacy_macos_install.sh --target acer-aspire-4310 --os snowleopard \
  --make-usb --disk /dev/diskX --retail input/SnowLeopard-Retail.iso
```

eMachines D640 examples:

```bash
./legacy_macos_install.sh --target emachines-d640-n930 --os snowleopard --doctor
./legacy_macos_install.sh --target emachines-d640-n930 --os snowleopard --download
./legacy_macos_install.sh --target emachines-d640-n930 --os snowleopard --build
sudo ./legacy_macos_install.sh --target emachines-d640-n930 --os snowleopard \
  --make-usb --disk /dev/sdX --retail /path/to/SnowLeopard10.6.3.iso
```

ASUS Eee PC 1215P pre-audit examples:

```bash
./legacy_macos_install.sh --target asus-eee-pc-1215p --os snowleopard --doctor
./legacy_macos_install.sh --target asus-eee-pc-1215p --os lion --doctor
```

Before enabling its build engine, boot Linux on the physical 1215P and collect the private hardware/ACPI report:

```bash
sudo ./scripts/collect_linux_hardware_v2.sh "$PWD/input/hardware" asus-eee-pc-1215p
```

See [`profiles/asus-eee-pc-1215p/README.md`](profiles/asus-eee-pc-1215p/README.md) for the current research baseline and audit checklist.

The existing Acer entry point remains available and keeps its current command behavior:

```bash
./prepare_aspire4310_macos.sh --doctor
./prepare_aspire4310_macos.sh --download
./prepare_aspire4310_macos.sh --build --os leopard
./prepare_aspire4310_macos.sh --build --os snowleopard
./prepare_aspire4310_macos.sh --list-disks
./prepare_aspire4310_macos.sh --make-usb --os snowleopard --disk /dev/diskX --retail /path/to.iso
./prepare_aspire4310_macos.sh --update-efi --os snowleopard --disk /dev/diskX --boot-slice /dev/diskXs1
./prepare_aspire4310_macos.sh --verify-usb --disk /dev/diskX
```

The dispatcher deliberately wraps rather than rewrites this proven pipeline.

## Profiles

Canonical layout:

```text
profiles/
  acer-aspire-4310/
    hardware.conf
    leopard/
      profile.conf
      kexts.conf
    snowleopard/
      profile.conf
      kexts.conf
    lion/
      profile.conf

  emachines-d640-n930/
    hardware.conf
    snowleopard/
      profile.conf
      kexts.conf
    lion/
      profile.conf
    mountainlion/
      profile.conf
    mavericks/
      profile.conf

  asus-eee-pc-1215p/
    README.md
    hardware.conf
    gma3150.conf
    snowleopard/
      profile.conf
      kexts.conf
    lion/
      profile.conf
```

Compatibility symlinks keep the old Acer engine and the existing D640 Snow Leopard implementation working without duplicating profile data.

## Installation methods

### Leopard / Snow Leopard

These continue to use the existing retail DVD/ISO restore path. The command chain and safety checks from `--doctor` through `--make-usb` are intentionally preserved for implemented targets.

The 1215P Snow Leopard profile is deliberately blocked at `--doctor` until its physical Linux report is reconciled. It is expected to use a retail 10.6.3 base, i386 kernelspace, an Atom-capable custom kernel, AHCI and the legacy GMA3150/GMA950 framebuffer path.

### Lion / Mountain Lion / Mavericks

These profiles use the OpenCore online-Recovery architecture:

```text
FAT32 USB
├── EFI/OC/...
└── com.apple.recovery.boot/
    ├── *.dmg
    └── *.chunklist
```

The recovery pair is obtained with OpenCore's `macrecovery.py`. This matches the current OpenCore/Dortania installation model instead of reusing the older DVD restore code. See [`docs/INSTALLATION_METHODS.md`](docs/INSTALLATION_METHODS.md).

## Weird BIOS troubleshooting

The eMachines D640 has a separate low-level USB boot probe:

```bash
./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe --list
sudo ./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe \
  --disk /dev/sdX --case mbr-direct
```

`--usb-probe` is intentionally opt-in. It is destructive and tests BIOS -> MBR -> PBR handoff independently of OpenCore/macOS, so it does **not** belong inside normal `--make-usb` automatically.

## Repository layout

```text
legacy_macos_install.sh          human-facing multi-target dispatcher
prepare_aspire4310_macos.sh      proven Acer legacy engine / compatibility CLI
profiles/                        laptop + OS profile hierarchy
scripts/                         implementation, audit and diagnostic helpers
docs/                            hardware/research/troubleshooting notes
input/                           user-supplied retail media, ACPI, kernels, private hardware reports
cache/                           downloaded/extracted working cache (ignored)
output/                          generated builds (ignored)
downloads/                       cached downloads; manifest is tracked
```

Most users should start with `legacy_macos_install.sh` and only call scripts under `scripts/` while debugging a specific subsystem.

## O2Micro SD card reader driver

The O2Micro `1217:7120` VoodooSDHCI work is maintained separately so this installer repository does not grow into a driver-development tree:

https://github.com/IlyaBOT/VoodooSDHCI-O2Micro-7120

That repository contains the reproducible source patch pipeline, Snow Leopard Xcode build helper, OpenCore install/rollback helpers and hardware-test notes.

## Safety

Disk-writing modes never run implicitly. Always inspect the selected device before `--make-usb`, keep backups, and use `--dry-run` where the selected implementation supports it. Planned profiles are intentionally doctor-only until their physical hardware and kernel/kext path are validated. The D640 USB probe is intentionally more destructive than the normal media builder and requires its own explicit invocation.
