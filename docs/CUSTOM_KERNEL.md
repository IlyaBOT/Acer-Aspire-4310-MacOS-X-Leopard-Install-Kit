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

## XNU 1228.5.20 trace-release

Для воспроизводимой остановки сразу после `Kernel boot args:` проект содержит отдельный
диагностический patch. Он основан строго на Apple `xnu-1228.5.20`, commit
`f3fe36d86c12b679329ee4b45af0fc971368bf18`, который входит в официальный release manifest
Mac OS X 10.5.4. Версия ядра, архитектура и RELEASE-конфигурация не меняются.

Patch добавляет только жёсткие `[XNU-TRACE ...]` вызовы `kprintf`:

- вокруг boot-artwork lookup, panic UI и progress UI в `PE_init_iokit()`;
- после каждого раннего шага `StartIOKit()` до регистрации platform expert;
- после возврата из IOKit до `bsd_init()`.

Подготовить pinned source и проверить применение patch можно на Linux или современном macOS:

```bash
./prepare_aspire4310_macos.sh --prepare-xnu-trace
```

Сама сборка XNU 1228 использует инструменты эпохи Leopard, которые отсутствуют в современном
Xcode: i386-capable GCC, MIG, csh, `decomment`, `relpath`, `seg_hack`, `libkld` и
`kextsymboltool`.
Builder намеренно останавливается, если какой-либо инструмент отсутствует или compiler не
создаёт i386 Mach-O. Нужна изолированная legacy Darwin build-среда с Xcode 3.x и tools из
соответствующего Apple open-source release:

```bash
./prepare_aspire4310_macos.sh --build-xnu-trace
```

Для сверки provenance официальный tag `mac-os-x-1054` фиксирует связанные компоненты:
`cctools@18acda4142e5a43362d44d3a5a01665e8c7d80e1`,
`bootstrap_cmds@df26aea3728854ec94a438b2bff58306d457cfef`,
`developer_cmds@2a55f1bd0d1ca529e7bb6728a872de2ffa1d1a92`,
`kext_tools@fc58a4f7334f7c09552c7a080e1ea2eeb1299df3`,
`IOKitUser@0b6712423a745bdab1ce83bb35ca500629f8314b` и
`Libstreams@2fc9581ce7dca3e157f5529af4ed25cfd513a4be`. Builder не скачивает Xcode и не
устанавливает эти инструменты в host `/usr/local`: это отдельная, потенциально конфликтующая
с современным Xcode операция.

Успешная сборка кладёт bootable kernel в `input/kernels/leopard/kernel`, а unstripped image
сохраняет в `output/xnu-trace/`. Затем custom EFI строится отдельно от vanilla:

```bash
./prepare_aspire4310_macos.sh --build --os leopard --kernel custom \
  --boot-preset diagnostic --kext-set minimal --runtime legacy \
  --apic drop-duplicate
```

Первый запуск сохраняет `minimal`, чтобы единственной переменной был kernel. После фото с
последней `[XNU-TRACE ...]` меткой можно сделать отдельный A/B с `--kext-set smc`.

### Изолированная build-VM

Практичный вариант — маленькая Darwin VM на Apple host: Leopard 10.5.8 с Xcode 3.1.x или,
как fallback, Snow Leopard 10.6.8 с Xcode 3.2.6. Достаточно 2 vCPU, 2 GB RAM и 20–24 GB
HFS+ диска; 3D, звук и USB passthrough для сборки не нужны. После установки Xcode следует
сделать snapshot, а сеть гостя можно отключить.

Не рассчитывать на современный GitHub TLS внутри Leopard. На host сначала выполнить
`--prepare-xnu-trace`, затем передать весь checkout в VM через локальный `scp` или read-only
образ. Cache содержит pinned Git tree, поэтому builder сможет повторно проверить commit и
patch без сетевого доступа.

Один `mach_kernel` или минимальный Darwin boot image не заменяет такую VM: сборке нужны
работающий userland и host-программы. `relpath` и `decomment` собираются из pinned
`bootstrap_cmds-60`, `seg_hack` и `libkld` — из `cctools-667.3`, а `kextsymboltool` — из
`kext_tools-117`; эти версии совпадают с официальным Mac OS X 10.5.4 source manifest.
