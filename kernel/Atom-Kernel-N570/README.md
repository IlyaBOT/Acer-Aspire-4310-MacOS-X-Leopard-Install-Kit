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
│   └── xnu/                         # vendored exact xnu-1504.3.12 snapshot
├── scripts/
│   ├── bootstrap_source.sh          # deterministic fallback source fetch
│   ├── audit_source.sh              # verify exact vanilla source assumptions
│   ├── build_vanilla.sh             # Snow Leopard/Xcode 3.2 I386 RELEASE build
│   ├── test_vanilla.sh              # Mach-O/version/symbol/source checks
│   ├── run_vanilla_pipeline.sh      # bootstrap + audit + build + validation
│   ├── apply_n570_atom_debug_patch.py # source-level model 28 + debug checkpoints
│   ├── build_n570_debug.sh          # I386 DEBUG build after patching
│   ├── test_n570_debug.sh           # patched kernel validation
│   ├── stage_kernel.sh              # copy a test kernel to mounted ESP
│   ├── prepare_qemu_image_linux.sh  # clone known-good USB and stage kernel
│   └── qemu_boot.sh                 # legacy BIOS/OpenDuet QEMU smoke boot
├── patches/
│   └── README.md
├── artifacts/                       # local build products; ignored
└── work/                            # OBJROOT/SYMROOT/DSTROOT; ignored
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

### Option A: use an existing raw test-disk image

Mount its ESP, then stage the kernel:

```bash
bash scripts/stage_kernel.sh \
  artifacts/vanilla/mach_kernel \
  /path/to/mounted/ESP
```

Boot it:

```bash
bash scripts/qemu_boot.sh /path/to/test-disk.raw
```

### Option B: clone the known-good physical USB on Linux

This reads the physical USB and writes only to a new image file:

```bash
sudo bash scripts/prepare_qemu_image_linux.sh \
  --source-disk /dev/sdX \
  --output "$PWD/artifacts/qemu/asus1215p-vanilla.raw" \
  --kernel "$PWD/artifacts/vanilla/mach_kernel"
```

Then:

```bash
bash scripts/qemu_boot.sh "$PWD/artifacts/qemu/asus1215p-vanilla.raw"
```

Default QEMU control CPU is `Penryn`, RAM is 2 GiB, SMP is 2, acceleration is TCG, and guest disk writes are discarded with QEMU snapshot mode. The machine boots through legacy BIOS/OpenDuet rather than native UEFI.

Environment overrides are supported:

```bash
QEMU_CPU=Penryn QEMU_MEM=2048 QEMU_SMP=2 bash scripts/qemu_boot.sh test.raw
```

After the Penryn control succeeds, the same vanilla kernel can be used for an Atom-negative control:

```bash
QEMU_CPU='n270,+lm,+nx' QEMU_MEM=2048 QEMU_SMP=4 bash scripts/qemu_boot.sh test.raw
```

The N270 CPU model has the same Intel family 6 / model 28 identity relevant to the XNU Atom whitelist. It is not a complete emulation of Pineview/NM10 or the ASUS motherboard. `+lm,+nx` makes the CPU-side test closer to the 64-bit-capable N570 while still booting the I386 kernel. Capture the QEMU serial log under `artifacts/qemu/`.

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

### QEMU Atom-profile test

Stage the patched kernel into a copy of the test image ESP, then boot with the Atom-like CPU profile:

```bash
QEMU_CPU='n270,+lm,+nx' QEMU_MEM=2048 QEMU_SMP=4 \
  bash scripts/qemu_boot.sh /path/to/patched-test.raw
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
