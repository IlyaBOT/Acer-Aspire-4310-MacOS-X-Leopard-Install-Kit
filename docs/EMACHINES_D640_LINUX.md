# eMachines D640 / Phenom II N930 Snow Leopard bring-up

Experimental Snow Leopard target for:

- eMachines D640, Phoenix V1.06 legacy BIOS
- AMD Phenom II N930 (K10/Champlain), CPUID `0x00100F53`
- no SSSE3 / no SSE4.1 / no AVX
- AMD RS880M + SB800
- ATI Mobility Radeon HD 5470 (Park) `1002:68E0`, subsystem `1025:0377`
- Realtek ALC272X
- Atheros AR9285 `168C:002B`
- Broadcom BCM57780 `14E4:1692`

The planned path is **Snow Leopard 10.6.3 -> 10.6.8 Combo Update**. Vanilla
XNU is not treated as bootable on this CPU.

## Kernel policy

The first-boot OpenCore policy is:

- IA32 OpenDuet/OpenCore
- `KernelArch=i386-user32`
- `KernelCache=Cacheless`
- `LegacyCommpage=True`
- explicit `arch=i386` boot argument
- AMD legacy kernel matched to the OS release

The installer kernel is expected to identify as **Darwin 10.3.0 / xnu-1504.3.12**.
After the 10.6.8 Combo Update, the kernel must identify as
**Darwin 10.8.0 / xnu-1504.15.3**.

## 1. Download project assets and AMD kernels

```bash
./scripts/prepare_emachines_d640_snowleopard.sh --download
./scripts/prepare_emachines_d640_snowleopard.sh --doctor
```

`--download` now also downloads and extracts the historical nawcom/qoopz AMD
kernel packages for 10.6.3 and 10.6.8. The downloader tries the historical
original URL and then queries the Internet Archive for a captured copy if the
original host is gone.

Prepared kernels are stored under:

```text
downloads/amd-kernels/10.6.3/legacy_kernel
downloads/amd-kernels/10.6.8/legacy_kernel
```

Each directory contains a SHA-256 manifest and source record. These historical
third-party binaries do not have project-maintained trusted reference hashes;
therefore the script also verifies the i386 Mach-O slice and Darwin/XNU version
strings before accepting them.

Kernel-only refresh:

```bash
./scripts/prepare_emachines_d640_snowleopard.sh --download-kernels
```

## 2. Inspect the 10.6.3 ISO before erasing a USB

```bash
sudo ./scripts/prepare_emachines_d640_snowleopard.sh --inspect-retail \
  --retail ~/SnowLeopard10.6.3.iso
```

The Linux writer prefers a native HFS/HFS+ block-device representation from the
hybrid ISO. If one is available, the installer filesystem is cloned block for
block. If only an ISO9660/UDF view is available, the writer falls back to an
explicitly experimental HFS+ + `rsync` path.

Use `--restore-mode block` to require block cloning, or `--restore-mode files`
to force the fallback. Default is `auto`.

## 3. Build the EFI

```bash
./scripts/prepare_emachines_d640_snowleopard.sh --build
```

Output:

```text
output/targets/emachines-d640-n930/snowleopard/opencore/
├── ESP/
├── OpenDuet/
├── Payload/
└── BUILD_REPORT.md
```

If the 10.6.3 AMD kernel is already cached, the build report records its hash.

## 4. Create the Linux USB

Dry-run first:

```bash
sudo ./scripts/prepare_emachines_d640_snowleopard.sh --make-usb \
  --disk /dev/sdX \
  --retail ~/SnowLeopard10.6.3.iso \
  --dry-run
```

Then create it:

```bash
sudo ./scripts/prepare_emachines_d640_snowleopard.sh --make-usb \
  --disk /dev/sdX \
  --retail ~/SnowLeopard10.6.3.iso
```

The script automatically uses the cached Darwin 10.3.0 AMD kernel. An explicit
override is still possible with `--kernel-1063 /path/to/kernel`.

The writer:

1. inspects the source before destructive writes;
2. creates GPT + 200 MiB FAT32 ESP;
3. clones a native HFS source when possible, otherwise uses the file-copy fallback;
4. preserves retail `/mach_kernel` as `/mach_kernel.original`;
5. installs the verified AMD kernel as `/mach_kernel`;
6. installs the generated EFI;
7. runs OpenCorePkg's own Linux `BootInstall_IA32.tool` for OpenDuet;
8. verifies `boot.efi`, OpenDuet and the expected Darwin kernel version.

Verify again manually:

```bash
sudo ./scripts/prepare_emachines_d640_snowleopard.sh --verify --disk /dev/sdX
```

## 5. 10.6.3 -> 10.6.8

Stage the upgrade kit before updating:

```bash
./scripts/prepare_emachines_d640_snowleopard.sh --stage-1068-upgrade
```

It creates:

```text
output/targets/emachines-d640-n930/snowleopard/upgrade-10.6.8/
├── legacy_kernel-10.8.0
├── install-legacy-kernel-10.8.0.sh
├── SHA256SUMS.txt
└── README.txt
```

If the Apple 10.6.8 Combo Update DMG is already in `downloads/`, it is copied
into the kit as well.

Update order on the running 10.6.3 system:

1. make a backup;
2. install Apple's 10.6.8 Combo Update;
3. **do not reboot** when the update finishes;
4. run `sudo ./install-legacy-kernel-10.8.0.sh` from the staged kit;
5. verify that the helper accepts Darwin 10.8.0 / xnu-1504.15.3;
6. reboot through the D640 OpenCore profile.

The helper backs up Apple's post-update `/mach_kernel` before replacing it.

## 6. Hardware-specific work still deferred

The physical Linux dump confirmed the HD 5470 connector map, AR9285, ALC272X,
BCM57780, Synaptics touchpad and SB800 AHCI. Automatic HD 5470 framebuffer,
Wi-Fi and AppleHDA patches remain disabled until their exact Snow Leopard
binaries are validated in real boot tests.
