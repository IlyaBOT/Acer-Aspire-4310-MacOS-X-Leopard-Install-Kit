# Optional CustomKernel

Custom kernel не обязателен для Celeron M 520: Intel 64 и SSSE3 подтверждены, поэтому первым
тестируется vanilla Apple XNU. Скрипт никогда не меняет kernel внутри retail image.

Поддерживаемые входы:

```text
input/kernels/leopard/kernel
input/kernels/leopard/kernelcache
input/kernels/leopard/prelinkedkernel
input/kernels/snowleopard/kernel
input/kernels/snowleopard/kernelcache
input/kernels/snowleopard/prelinkedkernel
```

Перед использованием вычисляется SHA-256 и проверяется Mach-O/fat architecture. Artifact без
подтверждённого i386 slice отклоняется. В `auto` vanilla profile всегда сохраняется, а custom
создаётся отдельно:

```text
output/<os>/opencore-custom/ESP/Kernels/
```

Именно корень ESP `/Kernels`, не `/EFI/OC/Kernels`, соответствует OpenCore 1.0.7
`Kernel -> Scheme -> CustomKernel`.

Явный build:

```bash
./prepare_aspire4310_macos.sh --build --os leopard --kernel custom
```
