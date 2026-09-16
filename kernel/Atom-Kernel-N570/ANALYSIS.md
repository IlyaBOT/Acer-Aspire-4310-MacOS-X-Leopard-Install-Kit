# Initial XNU 1504.3.12 analysis for Atom N570

## Confirmed source baseline

The pinned Apple source is `xnu-1504.3.12`, commit:

```text
902cc0cd840e5c2a7b111bc1781e3c0625ebff5c
```

This is the XNU version used by Darwin 10.3.0 / Mac OS X 10.6.3.

## Early boot path worth instrumenting later

For the 32-bit kernel the relevant early path is approximately:

```text
boot.efi
  -> XNU entry/bootstrap assembly
  -> vstart(boot_args_start)
  -> Idle_PTs_init()
  -> cpu_data_alloc()/cpu_desc_init()
  -> cpu_mode_init()
  -> i386_init(boot_args_start)
  -> cpu_init()
  -> PE_init_platform(FALSE, ...)
  -> PE_init_kprintf()
  -> i386_vm_init()
  -> tsc_init()
  -> power_management_init()
  -> PE_init_platform(TRUE, ...)
  -> processor_bootstrap()
  -> thread_bootstrap()
  -> machine_startup()
```

`osfmk/i386/i386_init.c` already has useful DEBUG-only `kprintf` calls in `vstart()` before normal console initialization. Once the vanilla build is proven, N570-specific checkpoints should be added here first.

Every new checkpoint must use exactly this prefix:

```text
[N570 ATOM-KERNEL]
```

## Confirmed CPU-identification blocker

The N570 reports CPUID signature `0x000106CA`:

- family = `6`
- base model = `0xC`
- extended model = `1`
- folded model = `0x1C` = decimal `28`

In vanilla XNU 1504.3.12, `cpuid_set_cpufamily()` in `osfmk/i386/cpuid.c` recognizes family 6 models including:

```text
13
14 (Yonah)
15 (Merom)
23 (Penryn)
26 (Nehalem)
30
31
46
```

Model `28` (Bonnell/Pineview Atom) is absent.

`cpuid_set_info()` then explicitly rejects a CPU if `cpuid_set_cpufamily()` returns `CPUFAMILY_UNKNOWN`:

```c
if ((strncmp(CPUID_VID_INTEL, info_p->cpuid_vendor, ...)) ||
   (cpuid_set_cpufamily(info_p) == CPUFAMILY_UNKNOWN))
        panic("Unsupported CPU");
```

Therefore an unmodified XNU 1504.3.12 kernel is expected to reject the physical N570 even though the CPU can execute the i386 kernel itself.

This is a source-level explanation for why some historical Atom kernels spoofed or patched CPU identification.

## What the existing six-byte binary patch actually does

The current experimental kernel modifies only six bytes in the i386 slice, in two three-byte instruction sequences.

### Patch A: extended model

Original:

```text
25 00 00 0F 00 C1 E8 10 A2
```

Relevant instructions:

```asm
and eax, 0x000F0000
shr eax, 16
```

Replacement:

```text
25 00 00 0F 00 31 C0 90 A2
```

Relevant replacement:

```asm
xor eax, eax
nop
```

Effect: forces the extracted CPUID extended-model field to zero.

### Patch B: base model

Original:

```text
25 F0 00 00 00 C1 E8 04 A2
```

Relevant instructions:

```asm
and eax, 0xF0
shr eax, 4
```

Replacement:

```text
25 F0 00 00 00 B0 0F 90 A2
```

Relevant replacement:

```asm
mov al, 0x0F
nop
```

Effect: forces the base model to `15`.

Together the patches transform the visible folded model from Atom model 28 into model 15, i.e. the Merom path accepted by vanilla XNU.

## Why this binary spoof is risky

It does more than bypass one `panic("Unsupported CPU")` check. It mutates the CPU model stored in XNU's global CPUID information, so downstream code can believe the Atom is actually a Merom.

A source-level Atom patch should instead preserve the real signature/model whenever possible and explicitly decide which existing CPU-family behavior is safe to reuse.

Candidate first source patch after vanilla validation:

1. Add a named Atom/Bonnell model constant for model 28.
2. Accept model 28 in `cpuid_set_cpufamily()`.
3. Initially map it to the least-dangerous compatible family behavior only where required.
4. Keep `cpuid_model == 28` intact.
5. Add explicit N570 diagnostics around CPUID, topology, TSC, LAPIC and early VM setup.
6. Verify every Merom-family assumption before inheriting it.

## Other areas to audit before declaring the patch complete

- `cpuid_set_cache_info()` and CPUID leaf handling for Pineview cache descriptors.
- core/thread topology: N570 is 2C/4T with Hyper-Threading.
- local APIC / secondary CPU startup.
- `tsc_init()` and invariant-TSC assumptions.
- power-management setup and MSR accesses.
- commpage capability selection and instruction feature flags.
- any family-specific performance-monitoring MSRs.
- any SSE3/SSSE3 assumptions in kernel or commpage code.

The N570 supports SSSE3, so the problem is not the same as old 64-bit Pentium 4 `LegacyCommpage` cases.

## Vanilla-first validation rule

Before any of the above changes are made:

1. Build the exact source as `RELEASE I386` on the working Snow Leopard/Xcode 3.2 machine.
2. Validate the Mach-O architecture and Darwin/XNU version strings.
3. Preserve SHA-256 and `mach_kernel.sys` symbols if available.
4. Boot the self-built vanilla kernel on a known-supported environment, preferably QEMU with `Penryn` first.
5. Only then create the first N570 source change.

This prevents a broken historical XNU build environment from being mistaken for an Atom patch failure.
