# Atom Kernel N570

Source-level Snow Leopard 10.6.3 kernel bring-up workspace for the ASUS Eee PC 1215P / Intel Atom N570.

## Scope

Pinned baseline:

- Apple XNU: `xnu-1504.3.12`
- Darwin: `10.3.0`
- Mac OS X: `10.6.3`
- Source commit: `902cc0cd840e5c2a7b111bc1781e3c0625ebff5c`
- Initial architecture: `I386`
- Initial kernel configuration: `RELEASE`

The first phase is intentionally **vanilla**. No Atom patch is allowed until the clean source can be built, statically validated, and boot-tested on a supported CPU / QEMU setup.

All future N570-specific diagnostic messages added to XNU must start with exactly:

```text
[N570 ATOM-KERNEL]
```

## Layout

```text
kernel/Atom-Kernel-N570/
├── SOURCE.lock
├── ANALYSIS.md
├── README.md
├── src/
│   └── xnu/                           # vendored exact xnu-1504.3.12 snapshot
├── scripts/
│   ├── bootstrap_source.sh            # deterministic fallback source fetch
│   ├── audit_source.sh                # verify exact vanilla source assumptions
│   ├── build_vanilla.sh               # Snow Leopard/Xcode 3.2 I386 RELEASE build
│   ├── test_vanilla.sh                # Mach-O/version/symbol/source checks
│   ├── run_vanilla_pipeline.sh        # bootstrap + audit + build + validation
│   ├── apply_n570_atom_debug_patch.py # source-level model 28 + debug checkpoints
│   ├── build_n570_debug.sh            # I386 DEBUG build after patching
│   ├── test_n570_debug.sh             # patched kernel validation
│   ├── stage_kernel.sh                # copy a test kernel to mounted ESP
│   ├── prepare_qemu_image_linux.sh    # legacy full-disk clone helper
│   ├── prepare_qemu_esp_linux.sh      # sparse GPT+ESP image; skips DVD payload
│   ├── prepare_qemu_esp_windows.ps1   # Windows sparse GPT+ESP image; skips DVD payload
│   ├── qemu_boot_vanilla.sh           # Unix/Linux/macOS: Penryn control VM
│   ├── qemu_boot_atom.sh              # Unix/Linux/macOS: Atom model-28 VM
│   ├── qemu_boot_vanilla.ps1          # Windows 10/11: Penryn control VM
│   ├── qemu_boot_atom.ps1             # Windows 10/11: Atom model-28 VM
│   └── qemu_boot.sh                    # compatibility wrapper -> vanilla profile
├── patches/
│   └── README.md
├── artifacts/                         # local build products; ignored
└── work/                              # OBJROOT/SYMROOT/DSTROOT; ignored
```

The source snapshot is committed on the `Atom-Kernel-N570` branch. `bootstrap_source.sh` remains as a deterministic fallback and verifies the same pinned commit.

## Phase 0: source audit

```bash
cd kernel/Atom-Kernel-N570
bash scripts/audit_source.sh
```

The audit must confirm that the tree is still vanilla and that XNU 1504.3.12 does **not** accept Intel family 6 model 28 in `cpuid_set_cpufamily()`.

## Phase 1: vanilla build on Snow Leopard

On the working Acer Snow Leopard machine with Xcode 3.2 and the 10.6 SDK:

```bash
cd kernel/Atom-Kernel-N570
bash scripts/run_vanilla_pipeline.sh
```

Equivalent manual sequence:

```bash
bash scripts/bootstrap_source.sh
bash scripts/audit_source.sh
bash scripts/build_vanilla.sh
bash scripts/test_vanilla.sh artifacts/vanilla/mach_kernel
```

The build script keeps all generated files outside `src/xnu`.

Expected primary output:

```text
artifacts/vanilla/mach_kernel
```

If available, `mach_kernel.sys` and `mach_kernel.dSYM` are preserved locally because they are useful for mapping later early-boot failures to symbols.

### Optional comparison with retail 10.6.3 kernel

This is informational only; independent builds are not required to be byte-identical:

```bash
bash scripts/test_vanilla.sh \
  artifacts/vanilla/mach_kernel \
  /path/to/retail-10.6.3-mach_kernel
```

## Phase 2: QEMU control boot

First validate the self-built vanilla kernel on a CPU model Snow Leopard already supports. Do **not** start by emulating Atom. The control test separates a broken historical build/toolchain from an Atom-specific failure.

### Prepare the boot disk image

The QEMU launchers expect a **whole bootable disk image** containing the same OpenDuet/OpenCore + Snow Leopard boot chain used for the physical machine. The required Snow Leopard test kernel must be staged as `Kernels/mach_kernel`. OpenCore preserves the basename requested by `boot.efi`; Snow Leopard requests `mach_kernel`, so a file named only `Kernels/kernel` is not used for this path.

On Linux, a known-good physical USB can be cloned and the vanilla kernel staged in one step:

```bash
sudo bash scripts/prepare_qemu_image_linux.sh \
  --source-disk /dev/sdX \
  --output "$PWD/artifacts/qemu/asus1215p-vanilla.raw" \
  --kernel "$PWD/artifacts/vanilla/mach_kernel"
```

For the Atom-patched test, make a separate base image and stage `artifacts/n570-debug/mach_kernel` into it. Keeping separate vanilla and Atom base images prevents accidentally testing the wrong kernel.

### VM design

Both platform implementations intentionally use a small deterministic VM by default:

```text
RAM:       1024 MiB
vCPU:      1
Machine:   legacy PC/i440FX-class
Disk:      IDE
Graphics:  std VGA
Input:     USB keyboard + tablet
Network:   disabled
Audio:     disabled
Accel:     TCG
```

`q35` is deliberately not the default. The real Eee PC 1215P is Pineview/NM10-era hardware, while Q35/ICH9 is a newer and materially different platform. The QEMU machine is only an early-XNU/CPU control environment; it is not intended to reproduce the ASUS board 1:1.

TCG is also deliberate. It keeps QEMU in control of the guest CPUID model on Linux, macOS and Windows. KVM/WHPX can be enabled manually, but they are not the baseline for comparing Penryn and Atom CPUID behavior.

No `isa-applesmc` device or OSK is required by these scripts. The prepared Hackintosh image is expected to use the same FakeSMC/OpenCore path as the physical test media.

Each launcher creates a small qcow2 overlay above the supplied base image. The base image is therefore not modified. By default the overlay is recreated for each run; set `QEMU_REUSE_OVERLAY=1` on Unix or pass `-ReuseOverlay` on Windows to keep it.

### Unix / Linux / macOS launchers

Vanilla Penryn control:

```bash
bash scripts/qemu_boot_vanilla.sh \
  "$PWD/artifacts/qemu/asus1215p-vanilla.raw"
```

Atom model-28 test:

```bash
bash scripts/qemu_boot_atom.sh \
  "$PWD/artifacts/qemu/asus1215p-atom.raw"
```

If QEMU is not installed, the Bash launchers try to install it using the host package manager:

- macOS: Homebrew, then MacPorts
- Debian/Ubuntu: `apt`
- Fedora/RHEL-family: `dnf`
- Arch-family: `pacman`
- SUSE-family: `zypper`

Set `QEMU_AUTO_INSTALL=0` to disable automatic installation.

Useful overrides:

```bash
QEMU_MEM=2048 QEMU_SMP=2 bash scripts/qemu_boot_vanilla.sh test.raw
QEMU_MEM=2048 QEMU_SMP=4 bash scripts/qemu_boot_atom.sh test.raw
QEMU_ACCEL=kvm bash scripts/qemu_boot_vanilla.sh test.raw
```

The Atom launcher defaults to:

```text
n270,+lm,+nx
```

QEMU's `n270` model supplies the Intel family 6 / model 28 identity that matters to the XNU Atom whitelist. `+lm,+nx` exposes capabilities closer to the 64-bit-capable N570 while the guest kernel itself remains I386. This is not a complete emulation of Pineview/NM10 or the ASUS motherboard.

The older command remains as a compatibility alias for the vanilla profile:

```bash
bash scripts/qemu_boot.sh test.raw
```

### Windows 10/11 PowerShell launchers

Vanilla Penryn control:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\scripts\qemu_boot_vanilla.ps1 `
  -Image .\artifacts\qemu\asus1215p-vanilla.raw
```

Atom model-28 test:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\scripts\qemu_boot_atom.ps1 `
  -Image .\artifacts\qemu\asus1215p-atom.raw
```

The PowerShell scripts first look for `qemu-system-x86_64.exe` in PATH and common install directories. If it is absent they try, in order:

1. `winget install --id SoftwareFreedomConservancy.QEMU -e`
2. Chocolatey, if already installed
3. Scoop, if already installed

After installation they refresh the process PATH and locate `qemu-img.exe` as well.

Optional Windows overrides:

```powershell
.\scripts\qemu_boot_vanilla.ps1 -Image .\test.raw -MemoryMB 2048 -Smp 2
.\scripts\qemu_boot_atom.ps1 -Image .\atom.raw -MemoryMB 2048 -Smp 4
.\scripts\qemu_boot_vanilla.ps1 -Image .\test.raw -Accelerator whpx
```

For the reproducible baseline, keep `-Accelerator tcg`.

### Logs

Per-profile logs and overlays are stored under:

```text
artifacts/qemu/vanilla-penryn/
artifacts/qemu/atom-n570/
```

Each run records:

```text
serial-YYYYMMDD-HHMMSS.log
qemu-YYYYMMDD-HHMMSS.log
```

The QEMU log enables `guest_errors,cpu_reset`; the serial log is intended for XNU serial/debug output when the guest boot arguments enable it.

### Pass criteria

For the vanilla Penryn control, reaching the XNU banner is already valuable:

```text
Darwin Kernel Version 10.3.0
```

If the self-built vanilla kernel cannot reach XNU on Penryn, stop there and debug the build/boot chain before applying Atom changes.

## Phase 3: source-level N570 bring-up patch

Only after the vanilla Penryn control boot succeeds, apply the first Atom patch locally:

```bash
python scripts/apply_n570_atom_debug_patch.py
```

On Snow Leopard the system Python 2.6 is sufficient; the helper is deliberately Python 2/3 compatible.

Review the change before building:

```bash
git diff -- src/xnu/osfmk/i386/cpuid.h \
            src/xnu/osfmk/i386/cpuid.c \
            src/xnu/osfmk/i386/i386_init.c
```

The first patch does three things only:

1. restores the explicit `CPUID_MODEL_ATOM = 28` definition;
2. accepts model 28 in `cpuid_set_cpufamily()` while preserving `cpuid_model == 28`;
3. adds early/late bring-up checkpoints using the mandatory `[N570 ATOM-KERNEL]` prefix.

For the initial bring-up hypothesis, Atom is mapped to `CPUFAMILY_INTEL_6_13`. This follows historical XNU-derived Atom handling and avoids lying that the CPU itself is Merom model 15. It is a hypothesis to validate, not the final semantic model.

Build the instrumented DEBUG I386 kernel:

```bash
bash scripts/build_n570_debug.sh
bash scripts/test_n570_debug.sh artifacts/n570-debug/mach_kernel
```

Expected artifact:

```text
artifacts/n570-debug/mach_kernel
```

Symbols, when produced, are retained as:

```text
artifacts/n570-debug/mach_kernel.sys
artifacts/n570-debug/mach_kernel.dSYM
```

After the DEBUG control has proven the Atom model-28 path, build the same patched source as RELEASE for an apples-to-apples comparison with the working vanilla RELEASE kernel. This removes MACH_ASSERT-only panics while preserving the Atom acceptance case and the direct `[N570 ATOM-KERNEL]` kprintf checkpoints:

```bash
bash scripts/build_n570_release.sh
bash scripts/test_n570_release.sh artifacts/n570-release/mach_kernel
```

Expected RELEASE artifact:

```text
artifacts/n570-release/mach_kernel
```

### QEMU Atom-profile test

Stage the patched kernel into the Atom test image ESP, then boot it with the dedicated launcher:

```bash
bash scripts/qemu_boot_atom.sh \
  "$PWD/artifacts/qemu/asus1215p-atom.raw"
```

Look for messages such as:

```text
[N570 ATOM-KERNEL] vstart: entered ...
[N570 ATOM-KERNEL] i386_init: before cpu_init
[N570 ATOM-KERNEL] i386_init: after cpu_init
[N570 ATOM-KERNEL] CPUID ... family=6 model=28 ...
[N570 ATOM-KERNEL] i386_init: before i386_vm_init ...
[N570 ATOM-KERNEL] i386_init: after tsc_init
```

The last emitted marker is the first coarse localization of an early boot failure.

## Phase 4: real ASUS Eee PC 1215P test

Keep the vanilla kernel and current known kernel backed up. Mount the actual USB ESP and stage the patched DEBUG kernel:

```bash
bash scripts/stage_kernel.sh artifacts/n570-debug/mach_kernel /path/to/mounted/ESP
```

Keep OpenCore on:

```text
KernelArch = i386
CustomKernel = true
```

Use verbose/debug boot arguments. Do not change unrelated OpenCore quirks in the same test. Boot the ASUS and record the last visible `[N570 ATOM-KERNEL]` marker. If the physical machine fails earlier than QEMU, compare CPU feature leaves/MSRs, APIC/TSC behavior, ACPI and memory-map differences next.

To restore the source tree after an experiment:

```bash
git restore src/xnu/osfmk/i386/cpuid.h \
            src/xnu/osfmk/i386/cpuid.c \
            src/xnu/osfmk/i386/i386_init.c
```

On older Git versions without `git restore`:

```bash
git checkout -- src/xnu/osfmk/i386/cpuid.h \
                src/xnu/osfmk/i386/cpuid.c \
                src/xnu/osfmk/i386/i386_init.c
```

## Rules

- Keep the initial `src/xnu` snapshot identical to Apple commit `902cc0cd840e5c2a7b111bc1781e3c0625ebff5c` until vanilla validation is complete.
- Never mix vanilla build fixes with Atom behavior changes.
- Every N570-specific debug print must start with `[N570 ATOM-KERNEL]`.
- Preserve SHA-256 and symbols for every test kernel.
- Prefer one behavioral hypothesis per patch/test kernel.
- Do not spoof the complete Atom model as Merom unless a specific downstream dependency proves that it is necessary.

## EFI-only QEMU image workflow

Do not clone the whole 60+ GiB USB for QEMU. The preferred helpers preserve the original logical disk geometry but copy only the boot-critical regions: MBR + primary GPT + partition 1 (ESP), plus the final 1 MiB containing the backup GPT. The Snow Leopard DVD/HFS partition payload is left as a sparse hole, so only roughly the ESP size is actually copied and allocated.

Windows 10/11, elevated PowerShell:

~~~powershell
.\scripts\prepare_qemu_esp_windows.ps1 -DiskNumber 7 -Profile vanilla
.\scripts\qemu_boot_vanilla.ps1 -InstallerISO "D:\ISO\Snow-Leopard-10.6.3.iso"
~~~

The Windows helper does not use Set-Disk -IsOffline because Windows rejects that operation for many removable USB devices. It opens PhysicalDrive read-only with shared access.

Linux:

~~~bash
sudo bash scripts/prepare_qemu_esp_linux.sh --source-disk /dev/sdX --profile vanilla
QEMU_INSTALLER_ISO="/path/to/Snow-Leopard-10.6.3.iso" bash scripts/qemu_boot_vanilla.sh
~~~

For the patched kernel, replace vanilla with atom. Outputs are:

~~~text
artifacts/qemu/asus1215p-vanilla-esp.raw
artifacts/qemu/asus1215p-atom-esp.raw
~~~

The HFS/DVD data is intentionally absent from these sparse images, so attach the original Snow Leopard 10.6.3 ISO as a QEMU CD-ROM. The launchers accept -InstallerISO on PowerShell, a second positional argument on Bash, or QEMU_INSTALLER_ISO in the environment.
