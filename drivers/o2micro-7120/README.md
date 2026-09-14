# O2Micro 1217:7120 SD card reader experiment

Target hardware: Acer Aspire 4310, O2Micro SD Host Controller `1217:7120`
(subsystem `1025:012f`, revision `02`), Snow Leopard 10.6.8 / Darwin 10.8.0
running an i386 kernel.

## Source lineage

The binary previously tested on the Acer was `IOSDHCIBlockDevice 1.0.0d1` from
`khronokernel/Legacy-Kexts`. Its original project was the SourceForge
**Darwin SDHCI Driver for JMicron Devices** project by Forest Godfrey/type_11.
The old SourceForge SVN is the historical source, but the easiest intact Git
source tree to build today is the directly related `coolstar/VoodooSDHCI`
project. Its source still carries the `IOSDHCIBlockDevice` project lineage and
GPL notice, and its Xcode project is explicitly Xcode 3.2 compatible.

This branch therefore does **not** modify the binary-only Legacy-Kexts copy.
Instead it pins and patches:

- upstream: `https://github.com/coolstar/VoodooSDHCI.git`
- commit: `be8dc240a3b979d629660daea0d59c108ea86311`

The upstream tree is not vendored. `prepare_o2micro_source.sh` clones the pinned
revision into ignored `cache/`, copies it to ignored `output/`, then applies the
local patch recipe.

## Why the first IOSDHCIBlockDevice test wedged the GUI

The Legacy-Kexts binary attached to `1217:7120` after adding PCI ID
`0x71201217`. With an SD card inserted it logged the 50 MHz base clock, 390 kHz
initial SD clock, and `initializing SD version 2.0 card`, then never completed
initialization. IOKit kept both the PCI device and driver service `busy 1`,
WindowServer became stuck, and removing the card immediately allowed the GUI to
continue.

The related VoodooSDHCI source contains the same class of failure mechanisms:

- `SDCommand()` explicitly used an unbounded spin while `ComInhibitCMD` stayed
  set.
- `Reset()` waited forever for the software-reset register to clear.
- `waitIntStatus()` had an intended timeout, but an inner infinite loop made the
  timeout unreachable.
- the legacy ACMD41 initialization path used an unbounded `do/while`.
- `calcClock()` had a precedence bug in its clock-stable test.

Linux has historically run `1217:7120` in PIO on at least some revisions and
reported an unusual SDHCI controller version, so the first test build avoids DMA
and performance features completely.

## First diagnostic build policy

The generated source deliberately uses:

- `1217:7120` PCI match
- i386 target
- verbose command tracing
- bounded command/reset/interrupt waits
- failed-card-init latch until physical removal
- PIO data path
- single-block I/O
- 1-bit bus
- **read-only mode**

This is a diagnostic build, not the final driver. The first objective is to get
card initialization to return success or a useful timeout/error without
blocking IOKit. Performance and writes come later.

## Build workflow

### 1. Modern Mac (macOS 12): prepare source

```bash
cd Acer-Aspire-4310-MacOS-X-Leopard-Install-Kit
git switch cardreader-o2micro-7120

./scripts/cardreader/bootstrap_macos12.sh
./scripts/cardreader/prepare_o2micro_source.sh
./scripts/cardreader/push_to_acer.sh
```

macOS 12 is only the source-preparation host. Modern Xcode no longer provides a
supported Snow Leopard i386 KEXT toolchain.

### 2. Acer / Snow Leopard: build with Xcode 3.2.x

Install Xcode 3.2.x with the 10.6 SDK. The helper can validate an existing
installation or install from a local Xcode DMG/package:

```bash
cd ~/Projects/VoodooSDHCI-O2Micro-7120
chmod +x bootstrap_snowleopard.sh build_snowleopard.sh install_opencore_snowleopard.sh

./bootstrap_snowleopard.sh
# or, if Xcode is not installed:
# ./bootstrap_snowleopard.sh --xcode-media ~/Desktop/Xcode_3.2.6.dmg

./build_snowleopard.sh .
```

Expected output:

```text
build-o2micro/VoodooSDHC.kext
```

### 3. Install through OpenCore

The current `/System/Library/Extensions/IOSDHCIBlockDevice.kext` test copy must
not coexist with the OpenCore-injected build. The installer can back it up and
rebuild Snow Leopard caches:

```bash
./install_opencore_snowleopard.sh \
  ./build-o2micro/VoodooSDHC.kext \
  --disable-sle-conflicts \
  --apply

The installer previews and exits unless `--apply` is supplied.
```

The OpenCore entry is limited to:

```text
Arch      = i386
MinKernel = 10.0.0
MaxKernel = 10.99.99
```

Remove the SD card for the first reboot.

## First test

Boot without an SD card, verify SSH/GUI, then run:

```bash
kextstat | grep -i VoodooSDHC
ioreg -p IOService -w0 | egrep 'pci1217,7120|VoodooSDHC'
```

Start a filtered kernel log in SSH:

```bash
while true; do
  sudo dmesg | egrep 'VoodooSDHCI/O2|VoodooSDHCI' | tail -80
  sleep 1
done
```

Then insert one known-good SD/SDHC card. The interesting lines are the exact
command number, `PresentState`, normal interrupt status (`NIS`), error interrupt
status (`EIS`), and `RESP0` at the first timeout/error.

Do **not** enable writes until basic enumeration and repeated insert/remove are
stable.
