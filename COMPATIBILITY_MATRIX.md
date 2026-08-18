# Static compatibility matrix

EFI уже дошёл до Leopard XNU на физическом Acer, но ядро пока не прошло ранний
`machine_init`. Поэтому успешная инъекция kext ещё не является проверкой работы устройства.

| Component | Leopard 10.5 i386 | Snow Leopard 10.6 i386 | Static evidence | Runtime |
|---|---|---|---|---|
| OpenCore 1.0.7 / OpenDuet IA32 | REQUIRED | CANDIDATE | upstream разрешает 10.4–10.5 i386 только с 32-bit firmware; PE32 i386 build validated; MAT profile panics and runtime-free profile resets, so Leopard auto uses legacy OpenRuntime plus targeted duplicate-MADT removal | REACHED XNU; DUPLICATE-MADT PROFILE PENDING |
| OpenCore 1.0.7 / OpenDuet X64 | INCOMPATIBLE | CANDIDATE_NOT_DEFAULT | 10.5 i386 недоступен на 64-bit firmware по upstream compatibility rules | PHYSICAL PANIC in `pmap_enter` |
| FakeSMC (`org.netkas.fakesmc`, v1) | LIKELY_COMPATIBLE | LIKELY_COMPATIBLE | universal i386+x86_64; Darwin 7/8 KPI floors | NOT TESTED |
| AppleACPIPS2Nub 1.0.0d1 | LIKELY_COMPATIBLE | LIKELY_COMPATIBLE | universal i386+x86_64; Darwin 8 KPI floors | NOT TESTED |
| VoodooPS2Controller 1.1.0 + plugins | LIKELY_COMPATIBLE | LIKELY_COMPATIBLE | parent/plugins contain i386; Darwin 8 KPI floors | NOT TESTED |
| VoodooHDA 0.2.1 | LIKELY_COMPATIBLE, FULL only | LIKELY_COMPATIBLE, FULL only | universal i386+x86_64; old IOAudio/KPI dependencies | NOT TESTED |
| VoodooBattery 1.2.1 | LIKELY_COMPATIBLE, FULL only | LIKELY_COMPATIBLE, FULL only | i386; Darwin 8 KPI floors | NOT TESTED |
| AHCIPort/ATAPort/SATA injectors | UNVERIFIED explicit fallback | UNVERIFIED explicit fallback | native AHCI confirmed at `8086:27c5`; Linux links at 1.5 Gbps, so native remains first test | NOT TESTED |
| VirtualSMC 1.3.7 | TOO_NEW | CANDIDATE_NOT_ENABLED | main binary has i386, but minimum OS is 10.6 and adds Lilu dependency | NOT TESTED |
| WhateverGreen current | TOO_NEW/NOT USED | TOO_NEW/NOT USED | native GMA950 path is required first | NOT TESTED |
| BCM5787M driver | POST_INSTALL_UNRESOLVED | POST_INSTALL_UNRESOLVED | physical PCI ID confirmed as `14e4:1693`; compatible Leopard binary/source still unresolved | NOT TESTED |

Build-time `KEXT_REPORT.tsv` records the exact enabled bundle IDs, versions, architectures and
executable SHA-256 for each output.
