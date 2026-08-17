# Static compatibility matrix

`Runtime` везде `NOT TESTED`, пока EFI не загружен на физическом Acer. Проверка i386 slice и
plist metadata не является обещанием реальной работы.

| Component | Leopard 10.5 i386 | Snow Leopard 10.6 i386 | Static evidence | Runtime |
|---|---|---|---|---|
| FakeSMC (`org.netkas.fakesmc`, v1) | LIKELY_COMPATIBLE | LIKELY_COMPATIBLE | universal i386+x86_64; Darwin 7/8 KPI floors | NOT TESTED |
| AppleACPIPS2Nub 1.0.0d1 | LIKELY_COMPATIBLE | LIKELY_COMPATIBLE | universal i386+x86_64; Darwin 8 KPI floors | NOT TESTED |
| VoodooPS2Controller 1.1.0 + plugins | LIKELY_COMPATIBLE | LIKELY_COMPATIBLE | parent/plugins contain i386; Darwin 8 KPI floors | NOT TESTED |
| VoodooHDA 0.2.1 | LIKELY_COMPATIBLE, FULL only | LIKELY_COMPATIBLE, FULL only | universal i386+x86_64; old IOAudio/KPI dependencies | NOT TESTED |
| VoodooBattery 1.2.1 | LIKELY_COMPATIBLE, FULL only | LIKELY_COMPATIBLE, FULL only | i386; Darwin 8 KPI floors | NOT TESTED |
| AHCIPort/ATAPort/SATA injectors | UNVERIFIED explicit fallback | UNVERIFIED explicit fallback | plist-only; target SATA PCI ID unknown | NOT TESTED |
| VirtualSMC 1.3.7 | TOO_NEW | CANDIDATE_NOT_ENABLED | main binary has i386, but minimum OS is 10.6 and adds Lilu dependency | NOT TESTED |
| WhateverGreen current | TOO_NEW/NOT USED | TOO_NEW/NOT USED | native GMA950 path is required first | NOT TESTED |
| BCM5787M driver | POST_INSTALL_UNRESOLVED | POST_INSTALL_UNRESOLVED | exact PCI ID/source/tag not yet verified | NOT TESTED |

Build-time `KEXT_REPORT.tsv` records the exact enabled bundle IDs, versions, architectures and
executable SHA-256 for each output.
