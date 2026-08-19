# Hardware IDs физического Acer Aspire 4310

Снимок с Linux получен 2026-08-19. Точные значения перенесены в
`config/hardware-ids.conf`, а обезличенный разбор — в
`docs/ASPIRE4310_HARDWARE_SNAPSHOT.md`. DMI serial/UUID и MAC намеренно не сохраняются в
Git. Повторный сбор нужен только после замены устройства, панели, CPU или платы.

Загрузите Linux LiveUSB и из корня проекта выполните:

```bash
./scripts/collect_linux_hardware.sh
```

Скрипт использует `sudo` только для read-only доступа к закрытым kernel/firmware
интерфейсам. Он сохраняет полный приватный архив в игнорируемом Git каталоге
`input/hardware/`, отдельно копирует каждую ACPI-таблицу и проверяет заявленную длину и
checksum. Также сохраняются EDID панели, i8042/Synaptics, HDA codecs, PCI/USB, sleep/wake
и kernel log.

Нужны строки для:

- SATA/IDE/AHCI controller;
- VGA controller (GMA950) и его PCI ID;
- Ethernet controller (ожидается BCM5787M, но ID не угадывать);
- Network controller/Wi-Fi;
- Audio device и codec lines в `dmesg`;
- FireWire/IEEE-1394 controller;
- USB webcam и Bluetooth VID:PID;
- modem, если он присутствует;
- PS/2/Synaptics input и battery/ACPI warnings.

Не подставляйте IDs из другого Aspire 4310: комплектации менялись.
