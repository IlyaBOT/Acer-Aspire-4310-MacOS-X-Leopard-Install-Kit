# OpenCore/OpenDuet strategy

На дату аудита latest stable release — OpenCore 1.0.7 (2026-03-20). Он выбран потому, что это
актуальный stable upstream, а не «старый bootloader для старой ОС». Release содержит:

- `X64/` и `IA32/` OpenCore trees;
- `Utilities/LegacyBoot/bootX64`, `bootIA32`, `boot0`, `boot1f32`;
- `BootInstall_X64.tool` и `BootInstall_IA32.tool`;
- matching `Docs/Sample.plist`, `Configuration.pdf` и `ocvalidate`.

Скрипт запрашивает latest release динамически. Каждый build создаётся из `Sample.plist` этого
же cache release и валидируется его же `ocvalidate`.

Для Leopard выбирается OpenCore/OpenDuet IA32 независимо от поддержки Intel 64 процессором.
По документации OpenCore 1.0.7, Mac OS X 10.4–10.5 с i386-архитектурой поддерживается только
на 32-битном firmware path. Поэтому явное сочетание `--os leopard --oc-arch x64` считается
ошибкой конфигурации и отклоняется до сборки.

## Leopard-specific config

```text
Booter/Quirks/FixupAppleEfiImages = true
Booter/Quirks/RebuildAppleMemoryMap = false
Booter/Quirks/EnableWriteUnprotector = true
Booter/Quirks/SetupVirtualMap = false
Booter/Quirks/SyncRuntimePermissions = false
Kernel/Emulate/DummyPowerManagement = true
Kernel/Scheme/CustomKernel = false (true only in separate custom build)
Kernel/Scheme/FuzzyMatch = true
Kernel/Scheme/KernelArch = i386-user32
Kernel/Scheme/KernelCache = Auto
Kernel/Quirks/AppleCpuPmCfgLock = false
Kernel/Quirks/LegacyCommpage = false
Kernel/Quirks/ProvideCurrentCpuInfo = false
Misc/Security/SecureBootModel = Disabled
Misc/Security/ScanPolicy = 0
Misc/Security/Vault = Optional
UEFI/Quirks/RequestBootVarRouting = false
```

`FixupAppleEfiImages` нужен с современным строгим OpenDuet loader для старых Apple `boot.efi`.
`SetupVirtualMap=false` обязателен для Leopard/Snow Leopard профилей с 32-битным ядром:
OpenCore документирует этот quirk как несовместимый с 32-битными ядрами. Первый физический
тест с ошибочным значением `true` дошёл до Darwin 9.4 `RELEASE_I386`, после чего получил
раннюю панику `pmap_enter: pv not in hash list` во время инициализации памяти.
Повторный тест с исправленным quirk, но OpenDuet X64 дал ту же панику. Backtrace проходит
через `machine_init` и `pmap_map`; EFI runtime descriptor передаётся ядру с нулевым
`VirtualStart` и сталкивается со служебной low-memory mapping XNU. Это подтвердило, что
Leopard нужен весь IA32 boot path, а не только i386-ядро внутри X64 OpenCore.
Физический CPU оказался CPUID `06F6`, один core, с Intel 64. Поэтому Leopard использует
`KernelArch=i386-user32`: OpenCore выбирает 32-битные ядро и userspace и сам передаёт
`-legacy`. В явных boot args остаётся только соответствующий реальной топологии `cpus=1`.

Полный DEBUG log с IA32 path показал следующий источник оставшейся паники: OpenRuntime
успешно загружается, `MAT support is 1`, а активны `RBMAP=1` и `RTPERMS=1`. Падающий
runtime range занимает `0x5000` байт — столько же, сколько четыре страницы `.text` и одна
страница `.rdata` в IA32 `OpenRuntime.efi`. Созданный MAT-разбиением descriptor остаётся с
`VirtualStart=0`, и Darwin 9.4 передаёт его в `pmap_map(0, ...)`. Legacy-профиль
`RebuildAppleMemoryMap=false`, `SyncRuntimePermissions=false`,
`EnableWriteUnprotector=true` убрал panic, но физический тест затем стабильно остановился
после `mig_table_max_displ = 79`. Контрольный `--runtime off` подтвердил, что OpenCore без
ошибок передаёт управление XNU, но машина немедленно аппаратно перезагружается до panic
handler. Поэтому `--runtime auto` для Leopard остаётся `legacy`, а runtime-free вариант
доступен только явно. `RequestBootVarRouting=false` во всех OpenDuet-профилях. Snow Leopard
auto сохраняет MAT-профиль `modern`.

Firmware SysReport содержит две валидные MADT с одним IOAPIC: `INTEL/CALISTGA` длиной 104
байта и Phoenix `PTLTD/\t APIC` длиной 90 байт, причём у IRQ0 различаются flags.
Linux 5.10 на том же ноутбуке сообщает `BIOS bug: multiple APIC/MADT found, using 0` и
успешно работает с первой таблицей; её IOAPIC расположен по `0xFEC00000`, GSI 0–23.
`--apic drop-duplicate` создаёт точную ACPI/Delete запись по signature, OEM table ID и
длине, удаляя только Phoenix-копию. После отдельно проверенных `legacy/native` и
`off/native` вариантов это следующий профиль по умолчанию; `--apic native` сохраняет
контрольный путь без фильтрации.
`DummyPowerManagement` — документированный OpenCore replacement для NullCPUPM, поэтому
последний не добавляется. `LegacyCommpage` не нужен: CPU имеет SSSE3, а профиль i386.

`ScanPolicy=0` выбран только для первой диагностики, чтобы не скрыть HFS installer. После
успешной загрузки его следует ужесточить. `Vault=Optional` нужен на этапе итераций; production
vault можно сделать после стабилизации EFI.

## Drivers

Стандартный Leopard driver set: `OpenRuntime.efi`, один HFS driver,
`Ps2KeyboardDxe.efi` и `Ps2MouseDxe.efi`; `OpenRuntime.efi` отсутствует только в явно
выбранном runtime-free режиме `off`.
`OpenPartitionDxe` в 10.5/10.6 profile не добавляется: OpenDuet уже
содержит нужную partition support, а документированная отдельная необходимость относится к
10.7–10.9 recovery.

Встроенная клавиатура Aspire работает через PS/2. Для `Ps2KeyboardDxe.efi` включены
`KeySupport=true`, legacy input protocol `KeySupportMode=V1`, порог удержания клавиши `9`
и `TakeoffDelay=10000`. Режим `Auto` на первом физическом тесте дошёл до picker, но не
зарегистрировал клавиши.

`EFI/BOOT/.contentVisibility` содержит точное значение `Disabled`. Это скрывает bootstrap
OpenCore из его собственного picker и не позволяет тайм-ауту рекурсивно запустить
архитектурный `BOOT*.efi`; установочный HFS+ раздел остаётся видимым и становится
единственным пунктом.

IA32 auto для Leopard использует `HfsPlus32.efi`: PE32 i386. X64 для совместимых профилей
использует `HfsPlusLegacy.efi` из pinned OcBinaryData commit: PE32+ x86-64 и без RDRAND
path. `OpenHfsPlus.efi` остаётся
source-available fallback. Два HFS drivers одновременно никогда не включаются.

## Debug

Первый boot использует DEBUG build, `Target=67`, `AppleDebug=true`, `ApplePanic=true` и
`-v keepsyms=1 debug=0x100`. Logs должны появляться на ESP. После стабильного boot можно
переходить на normal preset/RELEASE отдельным будущим этапом.
