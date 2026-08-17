# Intel Celeron M 520 research

Intel `Celeron M Processor 500 Series Datasheet`, document 316205-003 (September 2007),
описывает семейство для Mobile Intel 945 Express и прямо указывает:

- single core, 1 MB L2, 533 MHz FSB;
- Intel 64 (EM64T);
- SSE, SSE2, SSE3 и SSSE3;
- семейство поддерживается ICH7M-era платформой.

Поэтому основной OpenDuet build — X64. Это не означает 64-bit Leopard kernel: OpenCore 1.0.7
документирует, что Mac OS X 10.5 не имеет x86_64 kernel и требует i386 kexts/patches. В config
используется `KernelArch=i386` и `KernelCache=Auto` (для 10.5 OpenCore автоматически выбирает
поддерживаемый Mkext вместо неподдерживаемой V1 prelinked injection).

Intel PCN 107423-00 документирует перевод Celeron M 520 с Merom B2 на Merom-L A stepping и
прямо говорит, что CPUID меняется. Поэтому единственный CPUID нельзя честно приписать
конкретному физическому ноутбуку по названию SKU. `TARGET_CPU_CPUID=VERIFY_ON_PHYSICAL_TARGET`.

Получить его можно с Linux LiveUSB:

```bash
lscpu
grep -m1 -E 'vendor_id|cpu family|model|stepping|flags' /proc/cpuinfo
cpuid -1 2>/dev/null || true
```

Итог:

```text
TARGET_CPU_SUPPORTS_LONG_MODE=YES
TARGET_CPU_SUPPORTS_SSE3=YES
TARGET_CPU_SUPPORTS_SSSE3=YES
TARGET_CPU_CPUID=VERIFY_ON_PHYSICAL_TARGET
OpenDuet default=X64
Leopard KernelArch=i386
```
