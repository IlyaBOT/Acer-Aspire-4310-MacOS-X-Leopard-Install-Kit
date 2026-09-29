# Carnations Botanica OpenCore 1.0.5 DEBUG

This directory contains the pinned prebuilt OpenCore archive used by the
ASRock FM2A58M-VG3+ R2.0 / AMD A8-7600 Mavericks target.

Source:
- repository: `Carnations-Botanica/OpenCorePkg`
- branch lineage: `royalDevelopment`
- pinned commit: `4d0803b5c1dbb12378e35712b213e531adde1d88`
- build type: X64 DEBUG
- source fallback AUDK: `audk-stable-202502`

The target intentionally uses:
- `OpenHfsPlus.efi` (not `HfsPlusLegacy.efi`);
- `OpenRuntime.efi`;
- UEFI boot through `EFI/BOOT/BOOTX64.efi`;
- OpenCore `CustomKernel` with `/Kernels/mach_kernel`.

The archive is generated once by
`.github/workflows/vendor-carnations-opencore.yml` and committed so a fresh
Linux LiveCD does not need Docker just to build this target.

Reference archive supplied during bring-up:
`OpenCore-1.0.5-DEBUG.zip`, SHA-256
`8b54a7311df2371e808c11b002cc6eba5a442540a3b7afbd078460aee8c7eb9d`.
The repository-generated ZIP container hash may differ because ZIP timestamps
can differ; the source commit and required contents are pinned and validated.
