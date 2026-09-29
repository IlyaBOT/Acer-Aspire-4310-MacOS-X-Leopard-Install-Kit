# Weird Legacy Laptops macOS Install Kit

A profile-driven toolkit for building and troubleshooting macOS/OpenCore install media for old laptops whose firmware, CPU or device mix does not fit a normal modern Hackintosh recipe.

> Repository slug is still `Acer-Aspire-4310-MacOS-X-Leopard-Install-Kit` for compatibility. The project itself is now organized as a multi-laptop installer kit.

## Current targets

| Target | Leopard | Snow Leopard | Lion | Mountain Lion | Mavericks |
| --- | --- | --- | --- | --- | --- |
| Acer Aspire 4310 | supported | supported | planned | — | — |
| eMachines D640 / Phenom II N930 | — | experimental, **physical target blocked** | planned | planned | planned |
| ASUS Eee PC 1215P / Atom N570 | — | experimental, **physical 10.6.3 Installer boot validated** | planned | — | — |
| ASRock FM2A58M-VG3+ R2.0 / AMD A8-7600 | — | — | — | — | experimental, **unvalidated hardware bring-up** |

`experimental` means the target is still under bring-up and is not yet a complete hardware-supported release. Some experimental targets may already have partial physical validation, documented below. `planned` means profile metadata and the installation architecture are defined, but build/destructive operations remain disabled.

### eMachines D640 status

The D640 profile and its Linux USB-writing backend are intentionally preserved, but the current physical test laptop is **not known working**. No successful OpenCore/macOS boot has been reproduced on it after the latest bring-up attempts. The remaining blocker may be failing hardware, unusually incompatible Phoenix legacy-BIOS behavior, or both; that diagnosis is not yet proven. Treat the D640 tooling as research/diagnostic code rather than a working-machine recipe.

The Linux media path itself remains useful: it can inspect a Snow Leopard image, create GPT + FAT32 ESP + HFS+ installer partitions, restore the installer, replace the legacy AMD kernel, install OpenDuet/OpenCore and run read-only verification. See `docs/EMACHINES_D640_LINUX.md` and `scripts/linux_make_usb.sh`.


### ASUS Eee PC 1215P status

Physical bring-up on the genuine Atom N570 target reached the functional Mac OS X 10.6.3 Installer GUI/userland using the source-built Darwin 10.3.0 i386 Atom kernel. Direct `sysctl machdep.cpu` output preserved the real CPU identity: family 6, model 28, stepping 10, signature `0x106CA`, 2 cores / 4 threads. The compatibility patch maps model 28 to the historical Yonah CPU-family path without spoofing the actual CPUID model or signature.

Confirmed on the physical machine: OpenDuet/OpenCore handoff, the custom XNU path, native ICH7/NM10 AHCI and the internal Kingston SSD, USB, the internal UVC webcam, PS/2 input, and a usable Installer GUI. The GMA3150 -> GMA950 device-property spoof is visible, but the Apple GMA framebuffer/acceleration kext was not loaded in the captured Installer session; the GUI was running through the generic `IONDRVFramebuffer` path, so QE/CI is not claimed.

The first physical match-trace boot appeared to stop around `IOResources: family specific matching fails`, but the machine was progressing extremely slowly. The major slowdown came from broad synchronous IOKit logging (`io=0x20007f`) plus the temporary match-trace instrumentation. The known-good pre-peripheral source/tooling state is tagged `n570-xnu-10.3.0-physical-r1`. A clean non-MATCHTRACE RELEASE kernel is now the baseline for subsequent hardware work; Ethernet, Wi-Fi, audio and battery remain experimental until their next physical runtime test.

### ASRock FM2A58M-VG3+ / AMD A8-7600 Mavericks status

A generated Linux hardware profile was promoted into a dedicated experimental
target for the ASRock FM2A58M-VG3+ R2.0 desktop with AMD A8-7600 (4 physical
cores / 4 threads), legacy BIOS/CSM, AMD FCH AHCI, Realtek RTL8111/8168 Ethernet,
Kaveri Radeon R7 iGPU and a discrete Turks XT Radeon HD 6670/7670.

The Mavericks path is pinned to Carnations Botanica's legacy AMD work:
`AMD-Kernel-Patches@f6860343d6a13ae954a0043cecb04a809faba0f8`,
including `10-9-Mavericks.plist` and the stock DEBUG
`extras/kernels/mavericks/mach_kernel`. The kernel is downloaded automatically
by the build/download pipeline and verified against the pinned Git blob SHA
before it is cached or copied into the target payload. The generator automatically changes
the Mavericks `cpuid_cores_per_package` patch to four physical cores, enables
`ProvideCurrentCpuInfo` and `FixupAppleEfiImages`, and sets first bring-up to
`KernelCache=Cacheless`.


The generic helper `scripts/download_carnations_amd_kernel.sh` can also select
the matching pinned `mach_kernel` for `snowleopard`, `lion`,
`mountainlion`, or `mavericks`. For the A8-7600 target this selection is
automatic: `--download`, `--build`, and `--apply-kernel` will fetch the
Mavericks kernel when it is not already present in cache.

Mavericks also requires TSC synchronization for this patch set. The default
minimal kext set therefore includes FakeSMC, NullCPUPowerManagement,
VoodooTSCSync (with `IOCPUNumber=3`) and legacy RealtekRTL8111 1.2.3.
VoodooHDA is available only in the full set because the captured Linux profile
identified the HDA PCI controllers but did not contain the actual codec ID.

The upstream AMD project currently requires its modified OpenCore fork. This
target pins `Carnations-Botanica/OpenCorePkg` royalDevelopment commit
`4d0803b5c1dbb12378e35712b213e531adde1d88`. On Linux, `--build` can build
that fork with Docker; an already downloaded/built OpenCore archive can instead
be passed with `--opencore-archive`.

First bring-up uses the discrete Radeon HD 6670/7670. Because this board still
exposes the Kaveri iGPU as PCI 00:01.0 even when firmware setup says it is
disabled, the generated OpenCore config blacklists
`PciRoot(0x0)/Pci(0x1,0x0)` for macOS by poisoning its early IOPCI match
properties (`name=unused`, `IOName=#display`, `class-code=FFFFFFFF`,
`vendor-id=FFFF`, `device-id=FFFF`). This is intentionally limited to the
Kaveri 1002:1313 function and leaves the Turks XT 1002:6758 dGPU untouched.

```bash
./legacy_macos_install.sh --target asrock-fm2a58m-vg3-a8-7600 --os mavericks --doctor
./legacy_macos_install.sh --target asrock-fm2a58m-vg3-a8-7600 --os mavericks --download
./legacy_macos_install.sh --target asrock-fm2a58m-vg3-a8-7600 --os mavericks --build

# after a writable Mavericks installer/system root is mounted:
sudo ./legacy_macos_install.sh --target asrock-fm2a58m-vg3-a8-7600 --os mavericks \
  --apply-kernel --volume /mnt/Mavericks
```

The target is not marked working until a real Mavericks boot is reproduced.

## Recommended entry point

```bash
./legacy_macos_install.sh --list-targets
./legacy_macos_install.sh --list-profiles
```

For an unknown x86/x86_64 PC, do **not** borrow the Acer profile just to inspect
hardware. Use the universal analyzer:

```bash
./legacy_macos_install.sh --profile universal --doctor
./legacy_macos_install.sh --profile new --os mavericks --doctor
```

`--profile universal` performs a read-only live analysis. `--profile new`
collects CPU/DMI/PCI/USB/storage/input/power data, emits `WARN` for missing or
unreliable fields, then asks for a profile name. The default name is generated
from `OS hostname + CPU model + i386/AMD64 + PC/Laptop`. Generated profiles
are local/private by default under `profiles/generated/`; they are
analysis-only and do not automatically choose an SMBIOS, kernel, kext or ACPI
strategy. See [docs/GENERIC_X86_PROFILE.md](docs/GENERIC_X86_PROFILE.md).

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
  --make-usb --disk /dev/sdX --retail /path/to/SnowLeopard10.6.3.iso --dry-run
```

ASUS Eee PC 1215P examples:

```bash
./legacy_macos_install.sh --target asus-eee-pc-1215p --os snowleopard --doctor
./legacy_macos_install.sh --target asus-eee-pc-1215p --os snowleopard --download
./legacy_macos_install.sh --target asus-eee-pc-1215p --os snowleopard --build
./legacy_macos_install.sh --target asus-eee-pc-1215p --os lion --doctor
```

See `profiles/asus-eee-pc-1215p/AUDIT.md` for the audited hardware snapshot and first-boot policy.

## OpenCore release selection

Implemented IA32/OpenDuet profiles can select a cached OpenCore build explicitly:

```bash
./legacy_macos_install.sh --target emachines-d640-n930 --download \
  --opencore-version 1.0.2 --opencore-variant debug

./legacy_macos_install.sh --target asus-eee-pc-1215p --build \
  --opencore-version 1.0.2 --opencore-variant release
```

`--opencore-version` also accepts `latest`; aliases are `--oc-version` and `--oc-variant`. The selector validates the IA32/OpenDuet files before changing `cache/current-sources.env`.

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

The dispatcher deliberately wraps rather than rewrites the proven target engines.

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
    AUDIT.md
    hardware.conf
    gma3150.conf
    snowleopard/
      profile.conf
      kexts.conf
    lion/
      profile.conf

  asrock-fm2a58m-vg3-a8-7600/
    hardware.conf
    mavericks/
      profile.conf
      kexts.conf

  generated/
    README.md
    <local-profile>/        # ignored by Git by default
      hardware.conf
      profile.conf
      profile.json
```

Compatibility symlinks keep the old Acer engine and the existing D640 Snow Leopard implementation working without duplicating profile data.

## Installation methods

### Leopard / Snow Leopard

These use retail DVD/ISO restore paths. The exact backend depends on target and host OS.

On macOS, Acer and ASUS use the existing `diskutil`/`asr` path. The D640 target additionally exposes the experimental Linux backend in `scripts/linux_make_usb.sh`, which prefers a native HFS/HFS+ block clone and falls back to an HFS+ + `rsync` copy when necessary.

The ASUS 1215P Snow Leopard profile starts from retail 10.6.3, IA32 OpenDuet/OpenCore, an i386 Atom-capable custom kernel, native ICH7/NM10 AHCI, PS/2 input and the audited GMA3150/GMA950 framebuffer path. This path has now reached the 10.6.3 Installer GUI/userland on the real Atom N570; post-install behavior and the remaining device drivers are still under validation.

### Lion / Mountain Lion / Mavericks

These profiles use the OpenCore online-Recovery architecture:

```text
FAT32 USB
├── EFI/OC/...
└── com.apple.recovery.boot/
    ├── *.dmg
    └── *.chunklist
```

The recovery pair is obtained with OpenCore's `macrecovery.py`. This matches the current OpenCore/Dortania installation model instead of reusing the older DVD restore code. See `docs/INSTALLATION_METHODS.md`.

## Weird BIOS troubleshooting

The eMachines D640 has a separate low-level USB boot probe:

```bash
./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe --list
sudo ./legacy_macos_install.sh --target emachines-d640-n930 --usb-probe \
  --disk /dev/sdX --case mbr-direct
```

`--usb-probe` is intentionally opt-in. It is destructive and tests BIOS -> MBR -> PBR handoff independently of OpenCore/macOS, so it does **not** belong inside normal `--make-usb` automatically. The probe pre-compiles its NASM templates before asking for destructive confirmation so a syntax/template failure cannot occur only after the disk has already been wiped.

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

Disk-writing modes never run implicitly. Always inspect the selected device before `--make-usb`, keep backups, and use `--dry-run` where the selected implementation supports it. Planned profiles remain doctor-only until their hardware kernel/kext path exists. Experimental profiles are not a claim of complete hardware support; any partial physical validation is documented explicitly per target. The D640 USB probe is intentionally more destructive than the normal media builder and requires its own explicit invocation.
