# OpenCore/OpenDuet strategy

На дату аудита latest stable release — OpenCore 1.0.7 (2026-03-20). Он выбран потому, что это
актуальный stable upstream, а не «старый bootloader для старой ОС». Release содержит:

- `X64/` и `IA32/` OpenCore trees;
- `Utilities/LegacyBoot/bootX64`, `bootIA32`, `boot0`, `boot1f32`;
- `BootInstall_X64.tool` и `BootInstall_IA32.tool`;
- matching `Docs/Sample.plist`, `Configuration.pdf` и `ocvalidate`.

Скрипт запрашивает latest release динамически. Каждый build создаётся из `Sample.plist` этого
же cache release и валидируется его же `ocvalidate`.

## Leopard-specific config

```text
Booter/Quirks/FixupAppleEfiImages = true
Booter/Quirks/RebuildAppleMemoryMap = true
Booter/Quirks/EnableWriteUnprotector = false
Booter/Quirks/SetupVirtualMap = true
Booter/Quirks/SyncRuntimePermissions = true
Kernel/Emulate/DummyPowerManagement = true
Kernel/Scheme/CustomKernel = false (true only in separate custom build)
Kernel/Scheme/FuzzyMatch = true
Kernel/Scheme/KernelArch = i386
Kernel/Scheme/KernelCache = Auto
Kernel/Quirks/AppleCpuPmCfgLock = false
Kernel/Quirks/LegacyCommpage = false
Kernel/Quirks/ProvideCurrentCpuInfo = false
Misc/Security/SecureBootModel = Disabled
Misc/Security/ScanPolicy = 0
Misc/Security/Vault = Optional
```

`FixupAppleEfiImages` нужен с современным строгим OpenDuet loader для старых Apple `boot.efi`.
`RebuildAppleMemoryMap` исправляет ограничения старого XNU; вместе с современным memory
attributes path выбраны `SyncRuntimePermissions=true` и `EnableWriteUnprotector=false`.
`DummyPowerManagement` — документированный OpenCore replacement для NullCPUPM, поэтому
последний не добавляется. `LegacyCommpage` не нужен: CPU имеет SSSE3, а профиль i386.

`ScanPolicy=0` выбран только для первой диагностики, чтобы не скрыть HFS installer. После
успешной загрузки его следует ужесточить. `Vault=Optional` нужен на этапе итераций; production
vault можно сделать после стабилизации EFI.

## Drivers

Minimal driver set: `OpenRuntime.efi`, один HFS driver, `Ps2KeyboardDxe.efi` и
`Ps2MouseDxe.efi`. `OpenPartitionDxe` в 10.5/10.6 profile не добавляется: OpenDuet уже
содержит нужную partition support, а документированная отдельная необходимость относится к
10.7–10.9 recovery.

Встроенная клавиатура Aspire работает через PS/2. Для `Ps2KeyboardDxe.efi` включены
`KeySupport=true`, legacy input protocol `KeySupportMode=V1`, порог удержания клавиши `9`
и `TakeoffDelay=10000`. Режим `Auto` на первом физическом тесте дошёл до picker, но не
зарегистрировал клавиши.

`EFI/BOOT/.contentVisibility` содержит точное значение `Disabled`. Это скрывает bootstrap
OpenCore из его собственного picker и не позволяет тайм-ауту рекурсивно запустить
`BOOTx64.efi`; установочный HFS+ раздел остаётся видимым и становится единственным пунктом.

X64 auto использует `HfsPlusLegacy.efi` из pinned OcBinaryData commit: PE32+ x86-64 и без
RDRAND path. IA32 auto использует `HfsPlus32.efi`: PE32 i386. `OpenHfsPlus.efi` остаётся
source-available fallback. Два HFS drivers одновременно никогда не включаются.

## Debug

Первый boot использует DEBUG build, `Target=67`, `AppleDebug=true`, `ApplePanic=true` и
`-v keepsyms=1 debug=0x100`. Logs должны появляться на ESP. После стабильного boot можно
переходить на normal preset/RELEASE отдельным будущим этапом.
