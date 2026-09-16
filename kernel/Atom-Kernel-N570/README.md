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
│   └── xnu/                  # exact xnu-1504.3.12 source snapshot
├── scripts/
│   ├── bootstrap_source.sh   # deterministic fallback source fetch
│   ├── build_vanilla.sh      # Snow Leopard/Xcode 3.2 I386 RELEASE build
│   ├── test_vanilla.sh       # source + Mach-O/version/symbol checks
│   ├── stage_kernel.sh       # copy a test kernel to mounted ESP/Kernels/kernel
│   └── qemu_boot.sh          # legacy BIOS/OpenDuet QEMU smoke boot
├── patches/
│   └── README.md
├── artifacts/                # local build products; do not commit binaries
└── work/                     # local OBJROOT/SYMROOT/DSTROOT
```

## Phase 1: vanilla build on Snow Leopard

On the working Acer Snow Leopard machine:

```bash
cd kernel/Atom-Kernel-N570
./scripts/bootstrap_source.sh
./scripts/build_vanilla.sh
./scripts/test_vanilla.sh artifacts/vanilla/mach_kernel
```

The build script uses the 10.6 SDK and keeps all generated files outside `src/xnu`.

Expected primary output:

```text
artifacts/vanilla/mach_kernel
```

If `mach_kernel.sys` is produced, it is kept as well because its symbols are useful for later early-boot debugging.

## Phase 2: QEMU control boot

First validate the self-built vanilla kernel on a CPU model Snow Leopard already supports. Do **not** start by emulating Atom. The control test is intended to distinguish a broken build/toolchain from an Atom-specific failure.

1. Make a raw clone/copy of the known-good Snow Leopard/OpenCore test disk.
2. Mount its ESP.
3. Stage the self-built kernel:

```bash
./scripts/stage_kernel.sh artifacts/vanilla/mach_kernel /path/to/mounted/ESP
```

4. Boot the image with a supported virtual Intel CPU:

```bash
./scripts/qemu_boot.sh /path/to/test-disk.raw
```

Default QEMU CPU is `Penryn` and the machine is legacy BIOS, matching the OpenDuet test path rather than native UEFI.

## Phase 3: N570 patching

Only after the vanilla artifact is known-good do we modify XNU. Initial source analysis is in `ANALYSIS.md`.

The first likely patch area is CPU identification in:

```text
osfmk/i386/cpuid.c
osfmk/i386/cpuid.h
```

The existing six-byte binary patch is deliberately **not** reproduced in source yet. Its behavior is documented in `ANALYSIS.md` so we can replace it with a source-level implementation instead of blindly spoofing CPUID fields.

## Rules

- Keep `src/xnu` at the exact pinned Apple commit until a patch branch/commit intentionally changes it.
- Never mix vanilla validation changes with Atom behavior changes.
- Every N570-specific debug print must use `[N570 ATOM-KERNEL]`.
- Preserve a vanilla artifact and SHA-256 for every patch iteration.
- Prefer one behavioral change per test kernel.
