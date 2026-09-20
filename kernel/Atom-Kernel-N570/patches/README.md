# N570 patch series

No XNU patch is applied in phase 1. This directory exists to keep source changes reviewable and reproducible after the vanilla build/control boot passes.

Planned first patch series:

1. `0001-cpuid-recognize-bonnell-model-28.patch`
2. `0002-early-n570-debug-checkpoints.patch`
3. later topology/TSC/LAPIC/commpage fixes only when a test demonstrates they are needed

## Mandatory debug prefix

Every diagnostic line introduced specifically for this work must begin with:

```text
[N570 ATOM-KERNEL]
```

Recommended source helper once patching begins:

```c
#define N570_LOG(fmt, args...) \
    kprintf("[N570 ATOM-KERNEL] " fmt, ##args)
```

Do not add this macro to the vanilla source before phase 1 passes.

## Patch discipline

- One behavioral hypothesis per patch/test kernel.
- Keep a SHA-256 and build log for every artifact.
- Do not spoof the complete CPU model unless a specific downstream dependency requires it.
- Prefer retaining the real family 6 / model 28 CPUID information.
- Never silently turn Atom into Merom in global CPUID state without documenting the downstream reason.
