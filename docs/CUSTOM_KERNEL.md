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

### Изолированная QEMU build-VM

Практичный вариант для Intel Mac — маленькая QEMU VM: Leopard 10.5.8 с Xcode 3.1.x или,
как fallback, Snow Leopard 10.6.8 с Xcode 3.2.6. Профиль использует IA32 EDK2, минимальный
OpenCore/FakeSMC, Penryn CPU, 1 vCPU, 2 GB RAM, 24 GB qcow2, IDE и e1000. Звук, 3D и USB
passthrough для сборки не нужны.

По умолчанию используется TCG. Для Snow Leopard существует воспроизводимый upstream QEMU
report: тот же guest загружается под TCG и перезагружается под HVF. Поэтому `--accel hvf`
оставлен только как явный A/B, а не как рабочий default.

На Intel Mac с поддерживаемой Homebrew версией macOS:

```bash
brew install qemu
```

Homebrew больше не предоставляет Intel bottle актуального QEMU для macOS 12 Monterey, а
сборка QEMU 11 требует более нового compiler, чем Apple Clang 14 этой системы. На Monterey
использовать официальный MacPorts installer для macOS 12, затем:

```bash
sudo /opt/local/bin/port install qemu
```

MacPorts port выбирает собственный совместимый Clang и включает необходимые проекту
x86_64, Cocoa, DMG и VVFAT возможности. Скрипт ищет QEMU как в `PATH`, так и напрямую в
`/opt/local/bin`, поэтому перезапуск Fish после установки не обязателен.

Версии QEMU периодически удаляют старые versioned machine types. VM helper читает
фактический `qemu-system-x86_64 -machine help` и автоматически выбирает самый старый
доступный `pc-i440fx-*`, не полагаясь на отсутствующий alias. Для диагностического A/B
конкретный доступный профиль можно задать через `XNU_QEMU_MACHINE=...`.

IA32 EDK2 подключается двумя pflash devices: immutable code и отдельный writable variable
store. Helper копирует оба исходных файла QEMU в ignored-каталог VM, снимает запись с code
и никогда не изменяет firmware/template из Homebrew или MacPorts. Копирование также не даёт
macOS filesystem compression пакета влиять на pflash I/O.

VM ESP дополнительно получает matching IA32 `OpenPartitionDxe.efi`: retail Leopard image
использует Apple Partition Map, которой нет в обычном EDK2 PartitionDxe. Только VM-копия
`config.plist` получает этот driver и фиксированный `1024x768@32`/`UIScale=1`; физический
Aspire profile остаётся без изменений. Cocoa запускается с `zoom-to-fit=off`, чтобы изменение
размера окна не искажало framebuffer.

В OVMF часть низкой памяти занята firmware, а Leopard использует фиксированные адреса для
kernel и kext modules. Инъекция FakeSMC сначала заканчивается `Couldn't allocate driver
module memory`; `AllowRelocationBlock` обходит allocation, но IA32 `boot.efi` затем падает
при финальном переносе блока. Поэтому VM не инжектирует FakeSMC и не включает relocation
block. Вместо этого helper добавляет штатный QEMU `isa-applesmc`, читая OSK0/OSK1 напрямую
из SMC Intel Mac небольшим локально собранным helper. Ключ не записывается в репозиторий и
не печатается в логах. Физическая сборка Aspire по-прежнему использует FakeSMC.

Если QEMU аварийно завершится, CPU reset/guest-error log сохраняется в
`output/xnu-qemu-vm/qemu-debug.log`, а helper печатает путь к последнему OpenCore log на
VM ESP. Это позволяет отличить XNU reboot/triple fault от ошибки OpenCore.

После установки QEMU:

```bash
./prepare_aspire4310_macos.sh --package-xnu-build-bundle
./prepare_aspire4310_macos.sh --create-xnu-qemu \
  --retail "/path/to/Leopard.iso"
./prepare_aspire4310_macos.sh --start-xnu-qemu \
  --retail "/path/to/Leopard.iso"
```

После установки guest запускается без `--retail`. NAT перенаправляет host
`127.0.0.1:2222` на guest SSH port 22. Для этого в guest надо включить Remote Login.
QEMU VM и её диск находятся только в ignored `output/xnu-qemu-vm/`.

Combo Update и Developer DVD подключаются как отдельные IDE media. QEMU читает Apple DMG
через штатный `dmg` driver, а для каждого исходного образа создаёт временный copy-on-write
snapshot. Поэтому IDE-устройство доступно гостю на запись, но исходный DMG/ISO не
конвертируется и не изменяется. Сначала обновить чистую 10.5.x VM до 10.5.8 и
перезагрузить её, затем подключить Xcode 3.1.x Developer DVD:

```bash
./prepare_aspire4310_macos.sh --start-xnu-qemu \
  --guest-media "/path/to/MacOSXUpdCombo10.5.8.dmg"
./prepare_aspire4310_macos.sh --start-xnu-qemu \
  --guest-media "/path/to/xcode-3.1.x-developerdvd.dmg"
```

`--guest-media` можно указать дважды, если installer ISO не подключён. Профиль i440fx
ограничен четырьмя IDE devices: два занимает ESP/qcow2, ещё два доступны образам. При
установке Xcode надо оставить включённым пакет
UNIX Development Support: он устанавливает compiler и command-line tools, необходимые
legacy XNU build.

Не рассчитывать на современный GitHub TLS внутри Leopard. Host-команда
`--package-xnu-build-bundle` заранее подготавливает patched XNU и pinned tool sources, затем
создаёт `output/xnu-trace/aspire4310-xnu-build-vm.tar.gz`. Передать bundle в guest можно
через локальный `scp -P 2222`; guest не требуется доступ к GitHub.

Один `mach_kernel` или минимальный Darwin boot image не заменяет такую VM: сборке нужны
работающий userland и host-программы. `relpath` и `decomment` собираются из pinned
`bootstrap_cmds-60`, `seg_hack` и `libkld` — из `cctools-667.3`, а `kextsymboltool` — из
`kext_tools-117`; эти версии совпадают с официальным Mac OS X 10.5.4 source manifest.
Внутри распакованного bundle выполнить:

```bash
./scripts/prepare_xnu_legacy_tools.sh --install
./scripts/build_xnu_trace.sh
```

Первый вызов устанавливает только проверенный набор host-tools в `/usr/local`; второй кладёт
готовый kernel в `input/kernels/leopard/kernel`. Полученный файл надо скопировать обратно в
одноимённый путь основного checkout.
