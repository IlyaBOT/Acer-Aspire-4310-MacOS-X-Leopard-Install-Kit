# Источники и provenance

Проверено 2026-08-19:

- OpenCorePkg releases: https://github.com/acidanthera/OpenCorePkg/releases
- OpenCore 1.0.7 Configuration source: https://github.com/acidanthera/OpenCorePkg/blob/1.0.7/Docs/Configuration.tex
- OpenCore changelog: https://github.com/acidanthera/OpenCorePkg/blob/master/Changelog.md
- Dortania legacy macOS installer/OpenDuet: https://dortania.github.io/OpenCore-Install-Guide/installer-guide/mac-install.html
- Dortania gathering files/HFS legacy: https://dortania.github.io/OpenCore-Install-Guide/ktext.html
- Dortania hardware limitations: https://dortania.github.io/OpenCore-Install-Guide/macos-limits.html
- OcBinaryData HFS drivers: https://github.com/acidanthera/OcBinaryData/tree/master/Drivers
- Intel Celeron M 500 Series datasheet 316205-003: https://www.intel.com/content/dam/support/us/en/documents/processors/mobile/celeron/sb/31620503.pdf
- Intel PCN 107423-00 for Celeron M 520 stepping/CPUID change: https://cdrdv2.intel.com/v1/dl/getContent/800179?fileName=PCN107423-00.pdf
- Apple Leopard 10.5.8 Combo Update: https://support.apple.com/en-us/106460
- Apple Snow Leopard 10.6.8 Combo Update v1.1: https://support.apple.com/en-us/106449
- Legacy kext candidate archive (commit-pinned at download): https://github.com/khronokernel/Legacy-Kexts
- VirtualSMC releases (static comparison only): https://github.com/acidanthera/VirtualSMC/releases
- XNU 1228.5.20 early kernel startup: https://github.com/apple-oss-distributions/xnu/blob/xnu-1228.5.20/osfmk/kern/startup.c
- XNU 1228.5.20 IPC initialization: https://github.com/apple-oss-distributions/xnu/blob/xnu-1228.5.20/osfmk/ipc/ipc_init.c

Исторические forum links из ТЗ используются только как hardware-specific leads, не как
автоматические binary sources:

- https://acerfans.ru/forum/topic_3272
- https://acerfans.ru/forum/topic_55/4
- https://www.insanelymac.com/forum/topic/265833-miniguide-iatkos-s3-v2-installation-on-the-acer-aspire-4310-mac-osx-1063/
- https://bbs.archlinux.org/viewtopic.php?id=99176 (аналогичный Calistoga/Phoenix BIOS с двумя MADT)

Каждая фактическая загрузка получает URL, version/commit, SHA-256, timestamp и VERIFIED status
в `downloads/manifest.tsv`.
