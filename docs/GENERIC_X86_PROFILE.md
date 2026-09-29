# Generic x86/x86_64 hardware-analysis profiles

The fixed Acer/eMachines/ASUS target profiles are intentionally machine-specific.
For an unknown PC, use the generic analyzer instead of borrowing one of those
profiles just to run `--doctor`.

## Read-only universal analysis

```bash
./legacy_macos_install.sh --profile universal --doctor
./legacy_macos_install.sh --profile universal --os mavericks --doctor
```

Aliases: `universal-x86` and `generic-x86`.

Universal mode detects the current machine and prints the result but does not
save anything.

## Create a new local profile

```bash
./legacy_macos_install.sh --profile new --os mavericks --doctor
```

The analyzer attempts to collect:

- OS hostname and x86 architecture;
- CPU model/vendor/topology and common instruction-set flags;
- DMI system, board, chassis/form-factor and firmware data;
- RAM;
- PCI GPU, audio, Ethernet, Wi-Fi/network, storage, USB and chipset devices;
- block storage;
- USB devices;
- connected DRM display modes;
- input-device names;
- battery information when present.

Missing tools, inaccessible DMI/sysfs data, malformed placeholder DMI strings,
and other incomplete reads are reported as `WARN`. Fields that cannot be
trusted are omitted where possible. Conservative fallbacks are used only for
core identity fields such as generic system model and PC/Laptop classification.

For example, if `lspci` is unavailable, the command remains usable but reports
that PCI-derived GPU/network/audio/storage fields were omitted.

## Profile name

At the end of an interactive `--profile new` run the tool suggests:

```text
OS Hostname + CPU Model + i386/AMD64 + PC/Laptop
```

Press Enter to accept it or type another name.

For automation:

```bash
./legacy_macos_install.sh --profile new --doctor \
  --name "Test AMD PC" --non-interactive
```

Generated profiles are stored under:

```text
profiles/generated/<slug>/
├── hardware.conf
├── profile.conf
└── profile.json
```

They are ignored by Git by default because hostnames and hardware inventories
may identify a machine.

A saved profile can be viewed again with:

```bash
./legacy_macos_install.sh --profile <slug> --doctor
```

## Scope and safety

A generated profile is **analysis-only**. Detection does not automatically
choose or assert compatibility for:

- SMBIOS;
- vanilla vs patched/custom XNU;
- OpenCore quirks;
- ACPI patches;
- GPU framebuffer/device properties;
- kexts;
- a macOS installer method.

This distinction is especially important for AMD CPUs. When an AMD processor is
detected the analyzer emits a warning that vanilla XNU compatibility must not be
assumed and that the required AMD kernel/patch path must be validated separately
for the requested macOS version.
