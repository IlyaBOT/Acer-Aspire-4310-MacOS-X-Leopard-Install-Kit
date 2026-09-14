# O2Micro 1217:7120 SD card reader fix

Hardware-tested on Acer Aspire 4310 with O2Micro SD Host Controller `1217:7120`
(subsystem `1025:012f`, revision `02`) under Mac OS X Snow Leopard 10.6.8 /
Darwin 10.8.0 using the i386 kernel.

## Status

**Working on real hardware.** The patched `VoodooSDHC.kext` loads, attaches to
the controller, initializes an SD card, exposes it through `IOBlockStorageDriver`,
and successfully performs repeated single-block `CMD17` reads with SDHCI
`Command Complete` (`NIS=0x0001`). A 2 GB FAT16 card was enumerated as a normal
BSD disk device.

The current known-good profile remains deliberately conservative:

- i386 only
- O2Micro PCI ID `1217:7120` added
- PIO data path
- single-block I/O
- 1-bit bus
- **read-only mode**
- verbose SDHCI diagnostics enabled

Write support, 4-bit mode, multiblock transfers and DMA have **not** been
hardware-validated yet. Do not describe this build as write-safe until those
paths are tested separately.

## Source lineage

The older binary tested during bring-up was `IOSDHCIBlockDevice 1.0.0d1` from
`khronokernel/Legacy-Kexts`. Its lineage traces back to the SourceForge
**Darwin SDHCI Driver for JMicron Devices** project. The easiest intact source
tree that still builds with the Snow Leopard-era toolchain is the related
`coolstar/VoodooSDHCI` project.

This repository does not vendor that upstream tree. It pins:

- upstream: `https://github.com/coolstar/VoodooSDHCI.git`
- commit: `be8dc240a3b979d629660daea0d59c108ea86311`

`prepare_o2micro_source.sh` exports that exact revision into ignored `output/`
and applies the reproducible local patch/hardening recipe.

## What was fixed

The original driver had several failure modes that could wedge IOKit during
card initialization:

- command completion was inferred from `ComInhibitCMD` instead of waiting for
  SDHCI `Command Complete`;
- command/reset/interrupt waits could spin indefinitely;
- interrupt status enables were lost after controller reset;
- stale W1C interrupt status was not handled robustly;
- the 16-bit SDHCI clock divider programming was wrong for common divisors such
  as `/2`;
- card power and initial clock sequencing were reversed;
- mandatory initialization commands were not consistently checked;
- failed initialization could leave media handling wedged instead of returning
  the slot offline until card removal.

The working path now powers the card first, establishes the ~400 kHz startup
clock, waits for real command completion/error status, then proceeds through the
normal SD initialization sequence before switching to 25 MHz.

## Reproduce the build

### 1. Prepare the pinned source

On a modern macOS/Linux host with Git and Python 3:

```bash
./scripts/cardreader/prepare_o2micro_source.sh
```

Generated tree:

```text
output/cardreader/VoodooSDHCI-O2Micro-7120/
```

### 2. Build on Snow Leopard

The KEXT must be built with the Snow Leopard-era i386 toolchain. Install Xcode
3.2.x with the MacOSX10.6 SDK, then from the repository root run:

```bash
./scripts/cardreader/build_snowleopard.sh \
  ./output/cardreader/VoodooSDHCI-O2Micro-7120
```

The helper validates the Mach-O architecture, `Info.plist`, O2Micro PCI match
and kext linkage without loading the new UUID over an already-running build.

Expected result:

```text
output/cardreader/VoodooSDHCI-O2Micro-7120/build-o2micro/VoodooSDHC.kext
```

## Install through OpenCore

Do not keep an old `IOSDHCIBlockDevice.kext` or `VoodooSDHC.kext` in
`/System/Library/Extensions` while injecting this build through OpenCore.

Preview:

```bash
./scripts/cardreader/install_opencore_snowleopard.sh \
  ./output/cardreader/VoodooSDHCI-O2Micro-7120/build-o2micro/VoodooSDHC.kext \
  --disable-sle-conflicts
```

Apply:

```bash
./scripts/cardreader/install_opencore_snowleopard.sh \
  ./output/cardreader/VoodooSDHCI-O2Micro-7120/build-o2micro/VoodooSDHC.kext \
  --disable-sle-conflicts \
  --apply
```

If needed, specify the EFI explicitly:

```bash
--efi-device disk0s1
```

The installer can fall back to `mount_msdos` on Snow Leopard systems where
`diskutil mount` refuses to mount an otherwise valid FAT EFI partition.

The OpenCore entry is limited to Darwin 10 / i386:

```text
Arch      = i386
MinKernel = 10.0.0
MaxKernel = 10.99.99
```

## Verification

Boot once without an SD card, then verify the driver:

```bash
kextstat | grep -i VoodooSDHC
ioreg -p IOService -w0 | egrep 'pci1217,7120|VoodooSDHC|IOBlockStorageDriver'
```

Insert a known-good card and inspect:

```bash
sudo dmesg | egrep -i 'VoodooSDHCI|O2:|CMD|timeout|error'
diskutil list
```

A healthy command path shows completion such as:

```text
VoodooSDHCI/O2: <- CMD17 complete ... NIS=0x0001 ...
```

## Rollback

Use:

```bash
./scripts/cardreader/remove_opencore_snowleopard.sh --efi-device disk0s1
```

The install helper also creates a timestamped backup of the previous OpenCore
configuration and any previous `VoodooSDHC.kext` on the Desktop.
