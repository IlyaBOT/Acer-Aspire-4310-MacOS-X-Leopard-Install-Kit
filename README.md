# Acer Aspire 4310 Legacy macOS Install Kit

Инструмент готовит проверяемые staging-деревья и загрузочную USB-флешку для:

1. Mac OS X Leopard 10.5.x → 10.5.8 — основной профиль;
2. Mac OS X Snow Leopard 10.6.x → 10.6.8 — вторичный профиль.

Основной backend — актуальная stable версия OpenCore через OpenDuet на legacy BIOS. Chameleon сохранён только как fallback из предоставленного пользователем проверяемого архива. Ни retail installer, ни дистрибутивы Kalyway/iATKOS/iDeneb/iPC/Hazard не скачиваются.

## Начало работы

На Intel Mac с macOS Monterey 12 или новее:

```bash
./prepare_aspire4310_macos.sh --doctor
./prepare_aspire4310_macos.sh --audit --volume "/Volumes/BOOT"
./prepare_aspire4310_macos.sh --download
./prepare_aspire4310_macos.sh --build --os leopard
```

Если пока нужны только небольшие OpenCore/kext/HFS assets без двух больших Apple Combo Updates:

```bash
./prepare_aspire4310_macos.sh --download --skip-combo-updates
```

Положите законно полученный retail-образ в один из путей:

```text
input/Leopard-Retail.dmg
input/Leopard-Retail.iso
input/SnowLeopard-Retail.dmg
input/SnowLeopard-Retail.iso
```

Или передайте путь к образу/смонтированному retail DVD через `--retail`.

## Безопасность дисков

Обычные `--doctor`, `--audit`, `--download` и `--build` не размечают диски. `--make-usb` работает только с whole-disk identifier `/dev/diskX`, показывает `diskutil info` и текущую таблицу `diskutil list`, запрещает `Internal: Yes` без дополнительного override и требует буквальный ввод:

```text
ERASE /dev/diskX
```

Не используйте существующую многосекционную флешку с важными данными для `--make-usb`, возьмите отдельную пустую флешку!

Названия томов не зашиты в код. Любой смонтированный том, из-за которого весь физический
диск должен стать недоступен для записи, можно защитить явно (опция повторяемая):

```bash
./prepare_aspire4310_macos.sh --make-usb ... \
  --protect-volume "/Volumes/KEEP"
```

Сначала можно посмотреть точный план без записи:

```bash
./prepare_aspire4310_macos.sh --make-usb --os leopard \
  --disk /dev/diskX --retail input/Leopard-Retail.iso --dry-run
```

### Сохранение существующего boot-раздела

Для внешнего GPT-диска ровно с двумя разделами отдельный режим сохраняет первый FAT32
boot-раздел, полностью заменяет на нём EFI/OpenDuet и стирает только второй раздел под
installer. Старые boot-файлы предварительно копируются в локальный игнорируемый
`backup/usb-.../`.

Сначала обязательно выполнить dry-run с явными whole-disk и slice identifiers:

```bash
./prepare_aspire4310_macos.sh --make-usb --layout preserve \
  --os leopard --bootloader opencore \
  --disk /dev/diskX \
  --boot-slice /dev/diskXs1 \
  --installer-slice /dev/diskXs2 \
  --retail input/Leopard-Retail.iso \
  --dry-run
```

Режим требует, чтобы boot-раздел был `s1`, заменяемый раздел — `s2`, а других разделов на
диске не было. Без `--dry-run` потребуется буквальное подтверждение с обоими slice IDs.
Обычный `--layout fresh` по-прежнему переразмечает весь выбранный диск.

## Build profiles

По умолчанию создаётся минимальный диагностический профиль:

```text
output/leopard/opencore-vanilla/ESP/
output/leopard/opencore-custom/ESP/     # только при наличии custom kernel
output/snowleopard/opencore-vanilla/ESP/
output/snowleopard/opencore-custom/ESP/
output/<os>/chameleon/                  # только с ручным архивом
```

В minimal входят лишь SMC emulator и legacy PS/2 stack. Audio, battery и SATA injectors добавляются только явно:

```bash
./prepare_aspire4310_macos.sh --build --os leopard --kext-set full
./prepare_aspire4310_macos.sh --build --os leopard --sata injected
```

Для пользовательского DSDT:

```bash
cp DSDT.aml input/acpi/
./prepare_aspire4310_macos.sh --build --os leopard --acpi patched
```

Для повторных boot-тестов готовый installer-раздел восстанавливать заново не нужно. Эта
операция пересобирает профиль, сохраняет старые boot-файлы в `backup/` и заменяет только
EFI/OpenDuet на первом разделе:

```bash
./prepare_aspire4310_macos.sh --update-efi --os leopard --bootloader opencore \
  --disk /dev/diskX --boot-slice /dev/diskXs1
```

## OpenCore choices

Версия не зашита навсегда: `--download` получает latest stable release через официальный GitHub API, сохраняет URL/SHA-256/timestamp в `downloads/manifest.tsv`, а config генерируется из `Docs/Sample.plist` именно этого release и проверяется его же `ocvalidate`.

Наличие Intel 64 у Celeron M 520 не означает, что для Leopard подходит OpenDuet X64.
OpenCore 1.0.7 поддерживает загрузку Mac OS X 10.4–10.5 с `KernelArch=i386` только через
32-битную firmware path, поэтому `--oc-arch auto` выбирает IA32. Явный X64 для Leopard
отклоняется до сборки: на физическом Aspire такой смешанный вариант доходил до XNU, но
падал в `pmap_enter: pv not in hash list` при обработке EFI runtime map.
Leopard config дополнительно фиксирует `arch=i386 -legacy cpus=1`: `KernelArch` выбирает
i386-срез, а `-legacy` не даёт Darwin 9 снова включить IA32e на EM64T-процессоре.

Физический IA32 DEBUG log сначала локализовал панику в MAT-разбитом descriptor
`OpenRuntime.efi` с нулевым `VirtualStart`. Legacy write-unprotect убрал панику, но XNU 9.4
затем воспроизводимо остановился сразу после `mig_table_max_displ = 79`. Поэтому Leopard
runtime-free тест без `OpenRuntime.efi` дошёл до XNU и вызвал немедленный аппаратный reset
до panic handler. Поэтому `--runtime auto` для Leopard снова выбирает `legacy`:
`OpenRuntime.efi` загружается, `EnableWriteUnprotector=true`, MAT rebuild выключен, а
`RequestBootVarRouting=false`. Непригодный runtime-free вариант сохранён только как явный
`--runtime off`; Snow Leopard auto использует `modern`.

SysReport и независимый Linux ACPI dump физического Aspire содержат две MADT. Linux прямо
помечает это как BIOS bug, выбирает первую `INTEL/CALISTGA`, а вторую Phoenix
`PTLTD/\t APIC` не использует. Профиль удаляет только вторую таблицу:

```bash
./prepare_aspire4310_macos.sh --build --os leopard --runtime legacy \
  --apic drop-duplicate --kext-set minimal
```

`--kext-set smc` оставляет только FakeSMC и исключает PS/2 kext metadata из ранней
инициализации ядра; UEFI PS/2-драйверы picker при этом сохраняются.

Эквивалентная явная команда:

```bash
./prepare_aspire4310_macos.sh --build --os leopard --oc-arch ia32
```

HFS auto-selection:

- IA32: `HfsPlus32.efi` (автоматический выбор для Leopard);
- X64: `HfsPlusLegacy.efi` (только для совместимых профилей; нет требования RDRAND);
- явный source-available fallback: `--hfs-driver openhfs`.

Одновременно включается ровно один HFS driver.

## Optional custom kernel

Vanilla никогда не перезаписывается. Файлы можно положить в:

```text
input/kernels/leopard/{kernel,kernelcache,prelinkedkernel}
input/kernels/snowleopard/{kernel,kernelcache,prelinkedkernel}
```

`--kernel auto` всегда строит vanilla и дополнительно custom profile, если найден статически подтверждённый i386 artifact. Подробнее: [CUSTOM_KERNEL.md](docs/CUSTOM_KERNEL.md).

## Chameleon fallback

Мёртвый исторический URL больше не используется. Для явного fallback положите архив с `i386/boot0`, `boot1h`, `boot` в:

```text
input/chameleon/chameleon-binaries.tar.gz
```

Затем:

```bash
./prepare_aspire4310_macos.sh --build --os leopard --bootloader chameleon
```

Автоматизированная GPT USB deployment-команда намеренно использует OpenCore/OpenDuet; Chameleon output остаётся отдельно для fallback режима.

## Документация

- [AUDIT.md](docs/AUDIT.md)
- [OPENCORE_LEGACY_NOTES.md](docs/OPENCORE_LEGACY_NOTES.md)
- [TARGET_CPU_RESEARCH.md](docs/TARGET_CPU_RESEARCH.md)
- [COLLECT_TARGET_HARDWARE_IDS.md](docs/COLLECT_TARGET_HARDWARE_IDS.md)
- [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- [COMPATIBILITY_MATRIX.md](COMPATIBILITY_MATRIX.md)
- [SOURCES.md](docs/SOURCES.md)
