# Диагностика первого boot

## OpenCore не появляется

Проверить GPT/ESP, root `boot`, соответствие `bootX64`/`bootIA32`, запуск matching
BootInstall tool, `EFI/OC/OpenCore.efi`, BIOS USB/F12 и DEBUG log. Для подтверждённого
Celeron M 520 и Leopard использовать IA32: поддержка Intel 64 процессором не отменяет
требование 32-битного firmware path для XNU 10.4–10.5.

## Picker появился, installer не виден

Проверить, что включён ровно один HFS driver нужной PE architecture, `ScanPolicy=0`, retail
partition действительно HFS+, и installer содержит `System/Library/CoreServices/boot.efi`.
Сделать `--verify-usb`; не добавлять второй HFS driver.

## boot.efi не стартует

Подтвердить `FixupAppleEfiImages=true`, OpenCore/OpenDuet architecture и architecture Apple
`boot.efi`. Не заменять release-компоненты файлами от другой OpenCore версии.

## Kernel стартует и падает

Проверить `KernelArch=i386`, `KernelCache=Auto`, `RebuildAppleMemoryMap=true`, FakeSMC и
`DummyPowerManagement=true`. Сначала vanilla; custom kernel — только отдельным A/B output.

Если Leopard падает в `pmap_enter: pv not in hash list` из `machine_init`/`pmap_map`, проверить
не только `SetupVirtualMap=false`, но и весь boot path: `OpenCore.efi`, `BOOTIA32.efi`, root
`boot` и установленный OpenDuet должны быть IA32. Сочетание X64 OpenDuet с
`KernelArch=i386` для Leopard не поддерживается.

## Still waiting for root device

Собрать точный SATA PCI ID и режим BIOS. Сначала native AHCI. Только затем отдельный build:

```bash
./prepare_aspire4310_macos.sh --build --os leopard --sata injected
```

Тестировать injectors по одному; текущий explicit set — диагностический fallback, не доказанное
решение.

## DSMOS / SMC error

Проверить наличие `FakeSMC.kext`, i386 slice, Kernel/Add path и dependencies. Latest
VirtualSMC 1.3.7 имеет i386 в основном binary, но `LSMinimumSystemVersion=10.6`, поэтому он не
подменяет Leopard FakeSMC candidate.

## PS/2 не работает

Проверить `AppleACPIPS2Nub`, parent `VoodooPS2Controller` и все nested plugins в Kernel/Add.
UEFI PS/2 drivers нужны для picker, kexts — для OS X.

## GMA950 black screen

Не ставить WhateverGreen. Сначала native AppleIntelGMA950 stack + MacBook2,1, verbose log и
external display. После этого исследовать device-properties/EFI injection под точный PCI ID.

## После первого успешного minimal boot

Порядок работ: GMA950 → Ethernet/Wi-Fi → audio/mic → battery → Bluetooth → FireWire → webcam
→ modem. Включать `--kext-set full` только по одному функциональному кандидату и сохранять
рабочий minimal output.
