# O2Micro 1217:7120 diagnostic SDHCI driver

This directory contains a source-prepared diagnostic derivative of
coolstar/VoodooSDHCI for the Acer Aspire 4310 O2Micro SD reader (PCI ID
1217:7120).

Status: source prepared; not compiled in this workspace and not installed on the
Acer. The build and install scripts are intentionally manual.

## Source provenance

The exact IOSDHCIBlockDevice 1.0.0d1 artifact is preserved as a binary in
khronokernel/Legacy-Kexts. Its Contents/Info.plist identifies class
IOSDHCIBlockDevice, version 1.0.0d1, and PCI match 0x2381197b. The repository
commit that added the binary is befe0db ("Add binaries").

No public source file or commit was found that proves a byte-for-byte match to
that binary. The closest usable GPL source is coolstar/VoodooSDHCI: its source
was imported from VoodooSDHCI SVN in commit a4ab1b1. The later be8dc24 commit
contains the source/project state used here. The source carries the original
GPL v2-or-later notice in License.h.

lvs1974/VoodooSDHCMod was compared as a later fork. It adds sleep/timer and
transfer changes, but its history also does not establish that it is the
1.0.0d1 binary's source. It is not used as the base of this diagnostic patch.

References:

- https://github.com/khronokernel/Legacy-Kexts/tree/4dfc274111abdc94e94498d1e76d9354f3700fc9/32Bit-only/IOSDHCIBlockDevice.kext
- https://github.com/khronokernel/Legacy-Kexts/commit/befe0dbad3b9bbbe86a45904a9fca575db2431a
- https://github.com/coolstar/VoodooSDHCI/commit/a4ab1b1e20b1a58cfe146d17b23b4512c4b6511a
- https://github.com/coolstar/VoodooSDHCI/commit/be8dc240a3b979d629660daea0d59c108ea86311
- https://github.com/lvs1974/VoodooSDHCMod/tree/a844efdbd7c65c4e321630036505963c6b7e7657

## Diagnostic patch

- Adds 0x71201217 to IOPCIMatch.
- Enables __DEBUG__ and READONLY_DRIVER.
- Sets numeric USE_SDMA to 0. The legacy SDMA implementation remains compiled
  for later comparison, but normal I/O selects PIO and the command builder does
  not set SDHCI_TRNS_DMA.
- Logs the controller PCI ID and every command before and after issuing it.
- Replaces the unbounded waits in Reset, SDCommand, calcClock, the legacy
  ACMD41 path, and waitIntStatus with bounded waits.
- Dumps the SDHCI register map on timeout/error.
- Keeps the existing bounded PIO transfer loops unchanged for this first
  diagnostic build.
- Restricts the project to i386 and the Mac OS X 10.6 SDK.
- Labels the bundle 1.1d1-o2m-diagnostic; it is not presented as the original
  IOSDHCIBlockDevice 1.0.0d1.

## Build on Snow Leopard

Use Xcode 3.2.6 on a Snow Leopard host:

~~~bash
./scripts/setup-build-snowleopard.sh
./scripts/build-snowleopard.sh --clean
~~~

Expected output:

~~~text
drivers/sdhci-o2micro/build/VoodooSDHC.kext
~~~

A modern macOS host is suitable for editing and Git operations, but this legacy
Xcode/project combination should be compiled on Snow Leopard.

## Manual OpenCore test

The default command only previews the operation:

~~~bash
./scripts/install-opencore-test.sh \\
  --kext drivers/sdhci-o2micro/build/VoodooSDHC.kext
~~~

After reviewing the printed paths, explicitly apply it:

~~~bash
./scripts/install-opencore-test.sh \\
  --apply \\
  --kext drivers/sdhci-o2micro/build/VoodooSDHC.kext \\
  --efi-mount /Volumes/EFI
~~~

The script backs up config.plist and any previous kext under
EFI/OC/_diagnostic-backups/, updates Kernel -> Add, runs plutil -lint, and does
not reboot unless --reboot is explicitly supplied.

## First diagnostic capture

After booting the test configuration, collect:

~~~bash
dmesg | grep VoodooSDHCI
tail -f /var/log/system.log
~~~

The first useful lines should include PCI controller 1217:7120, CMD0, CMD8,
CMD55, and CMD41. If a timeout occurs, preserve the complete register dump
before changing another variable. Because READONLY_DRIVER is enabled, writes
are rejected by design.
