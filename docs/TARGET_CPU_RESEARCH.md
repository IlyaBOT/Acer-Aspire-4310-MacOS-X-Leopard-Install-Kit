# Intel Celeron M 520 research

Intel `Celeron M Processor 500 Series Datasheet`, document 316205-003 (September 2007),
описывает семейство для Mobile Intel 945 Express и прямо указывает:

- single core, 1 MB L2, 533 MHz FSB;
- Intel 64 (EM64T);
- SSE, SSE2, SSE3 и SSSE3;
- семейство поддерживается ICH7M-era платформой.

Наличие Intel 64 не делает X64 OpenDuet пригодным для Leopard. Для Mac OS X 10.5 OpenCore
использует целиком IA32 firmware path, `KernelArch=i386` и `KernelCache=Auto` (для 10.5
автоматически выбирается поддерживаемый Mkext вместо V1 prelinked injection).

Intel PCN 107423-00 документирует перевод Celeron M 520 с Merom B2 на Merom-L A stepping и
прямо говорит, что CPUID меняется. Linux на физическом ноутбуке снял family 6, model 15,
stepping 6, то есть CPUID `0x000006F6`; также подтверждены одно ядро, 133 MHz base clock,
PAE, NX, Intel 64 и SSSE3.

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
TARGET_CPU_CPUID=0x000006F6
OpenDuet default=IA32
Leopard KernelArch=i386
Leopard boot-args include arch=i386 -legacy cpus=1
```
