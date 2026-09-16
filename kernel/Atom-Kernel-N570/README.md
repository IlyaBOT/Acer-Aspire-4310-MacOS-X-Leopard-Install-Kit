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
│   ├── stage_kernel.sh              # copy test kernel to mounted ESP
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

## Phase 3: N570 patching

Only after the vanilla artifact is known-good do we modify XNU. Initial source analysis is in `ANALYSIS.md`.

The first likely patch area is CPU identification in:

```text
osfmk/i386/cpuid.c
osfmk/i386/cpuid.h
```

The existing six-byte binary patch is deliberately **not** applied to the source tree. Its behavior is documented in `ANALYSIS.md` so it can be replaced by an explicit source-level implementation instead of globally falsifying the CPU model.

## Rules

- Keep the initial `src/xnu` snapshot identical to Apple commit `902cc0cd840e5c2a7b111bc1781e3c0625ebff5c` until vanilla validation is complete.
- Never mix vanilla build fixes with Atom behavior changes.
- Every N570-specific debug print must start with `[N570 ATOM-KERNEL]`.
- Preserve SHA-256 and symbols for every test kernel.
- Prefer one behavioral hypothesis per patch/test kernel.
- Do not spoof the complete Atom model as Merom unless a specific downstream dependency proves that it is necessary.
