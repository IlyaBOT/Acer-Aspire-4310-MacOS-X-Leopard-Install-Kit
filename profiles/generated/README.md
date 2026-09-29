# Generated hardware-analysis profiles

This directory is reserved for profiles created by:

```bash
./legacy_macos_install.sh --profile new --doctor
```

Generated subdirectories are ignored by Git by default because they can contain
hostnames and a detailed hardware inventory. A generated profile is analysis
metadata only; it does not imply macOS compatibility and does not select an
SMBIOS, kernel, kext, ACPI patch, bootloader architecture or installer method.

Each generated profile contains:

- `hardware.conf` — shell-readable sanitized target facts;
- `profile.conf` — profile metadata such as display name and architecture;
- `profile.json` — structured details, warnings and raw PCI/USB inventory.

Review a generated profile before copying selected facts into a tracked target.
