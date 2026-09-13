# eMachines D640 / Phenom II N930 Snow Leopard bring-up

This is an experimental target profile for:

- eMachines D640, Phoenix V1.06 legacy BIOS
- AMD Phenom II N930 (K10/Champlain), CPUID `0x00100F53`
- AMD RS880M + SB800
- ATI Mobility Radeon HD 5470 (Park) `1002:68E0`, 512 MB
- Realtek ALC272
- Atheros AR5B95 / AR9285-class WLAN

The first target is **Snow Leopard with an i386 legacy AMD kernel**. Vanilla
XNU is deliberately not treated as bootable on this CPU.

## 1. Collect the physical machine

Boot Linux on the D640 and run:

```bash
sudo ./scripts/collect_linux_hardware_v2.sh input/hardware emachines-d640-n930
```

The resulting private archive includes raw ACPI tables, PCI config space and
subsystem IDs, USB descriptors, EDID, HDA codec dumps and a best-effort display
VBIOS dump. Do not commit the archive: it can contain serial numbers and MACs.

## 2. Prepare upstream assets

```bash
./scripts/prepare_emachines_d640_snowleopard.sh --download
./scripts/prepare_emachines_d640_snowleopard.sh --doctor
```

The project still does not download retail Mac OS X media.

## 3. Build the target EFI

```bash
./scripts/prepare_emachines_d640_snowleopard.sh --build
```

Output:

```text
output/targets/emachines-d640-n930/snowleopard/opencore/
├── ESP/
│   ├── boot
│   └── EFI/
├── OpenDuet/
└── BUILD_REPORT.md
```

Default bring-up choices:

- IA32 OpenDuet/OpenCore
- `HfsPlus32.efi`
- i386 kernel architecture
- diagnostic `-v keepsyms=1 debug=0x108 io=0x20007f`
- FakeSMC + legacy PS/2 stack
- no Acer-specific ACPI deletion
- no automatic HD 5470 / Wi-Fi / AppleHDA patching

## 4. Create the USB on Linux

A user-supplied AMD K10 Snow Leopard kernel is mandatory for the real D640.
The writer preserves the retail `/mach_kernel` as `/mach_kernel.original` and
then installs the supplied kernel as `/mach_kernel`.

```bash
sudo ./scripts/prepare_emachines_d640_snowleopard.sh --make-usb \
  --disk /dev/sdX \
  --retail ~/SnowLeopard-Retail.iso \
  --amd-kernel ~/legacy_kernel
```

Dry-run first:

```bash
sudo ./scripts/prepare_emachines_d640_snowleopard.sh --make-usb \
  --disk /dev/sdX \
  --retail ~/SnowLeopard-Retail.iso \
  --amd-kernel ~/legacy_kernel \
  --dry-run
```

Verify after creation:

```bash
sudo ./scripts/prepare_emachines_d640_snowleopard.sh --verify --disk /dev/sdX
```

## 5. Hardware-specific work intentionally deferred

### Radeon HD 5470

Do not inject an `Eulemur` connector table blindly. First collect the VBIOS,
EDID, PCI subsystem IDs and actual LVDS/HDMI/VGA connector map. The target
profile currently leaves ATI5000Controller/framebuffer edits disabled.

### Wi-Fi

AR9285/`168C:002B` is expected from the current Windows inventory, but the exact
PCI and subsystem IDs must be confirmed from `lspci -nnk` before changing
`IO80211Family`.

### Audio

VoodooHDA is exposed only as an optional bring-up candidate. ALC272 AppleHDA
work should be done later and must not be mixed with VoodooHDA in the same test.

### ACPI

No DSDT/SSDT patch is generated from the Acer 4310 profile. If a patch becomes
necessary, place only reviewed AML files in:

```text
input/targets/emachines-d640-n930/acpi/
```

and build with `--acpi patched`.

## 6. Post-install kernel

The installer USB kernel replacement does not automatically modify the newly
installed system. Before the first HDD boot, the working AMD kernel must also
replace the installed system's `/mach_kernel` (with a backup kept). Automating
this is intentionally deferred until the exact kernel/version combination has
been proven on the physical N930.
