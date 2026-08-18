# Hardware IDs физического Acer Aspire 4310

Снимок с Linux получен 2026-08-19. Точные значения перенесены в
`config/hardware-ids.conf`; DMI serial/UUID намеренно не сохраняются в Git. Повторный сбор
нужен только после замены устройства или платы.

Загрузите любой современный Linux LiveUSB и сохраните вывод без редактирования:

```bash
sudo lspci -nn > lspci-nn.txt
sudo lspci -nnk > lspci-nnk.txt
sudo lsusb > lsusb.txt
sudo dmesg > dmesg.txt
lscpu > lscpu.txt
```

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
