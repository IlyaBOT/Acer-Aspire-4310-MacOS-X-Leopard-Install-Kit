# Aspire 4310 build report

Generated: 2026-08-18T00:37:04Z

## Host

- OS: Linux unknown (unknown)
- Architecture: x86_64
- CPU: Intel(R) Xeon(R) CPU E5-2660 v2 @ 2.20GHz
- Status: UNSUPPORTED BUILD HOST

## Target

- Model: Acer Aspire 4310
- CPU: Intel Celeron M 520 (Intel 64 and SSSE3 confirmed; physical CPUID still to collect)
- Chipset/GPU: Intel 943GML Express / ICH7M-era platform / Intel GMA950

## OS and bootloader

- Profile: Mac OS X Leopard 10.5.x
- Target final version: 10.5.8
- OpenCore: 1.0.7 DEBUG
- OcBinaryData commit: e74e533d8f89c1d5014cfb47c185502bf415741f
- Legacy-Kexts candidate commit: 4dfc274111abdc94e94498d1e76d9354f3700fc9
- OpenDuet: IA32
- HFS driver: HfsPlus32.efi
- Kernel profile: vanilla
- KernelArch: i386
- KernelCache: Auto
- CustomKernel: false
- Boot preset: diagnostic
- Kext set: minimal
- SATA: native
- ACPI: native

## Kexts

Every enabled executable was statically checked for an i386 slice. Plist-only injectors are
identified separately; static compatibility is not a claim of runtime functionality.

| Bundle | Bundle ID | Version | Architectures | Minimum OS | SHA-256 | Status |
|---|---|---:|---|---|---|---|
| `AppleACPIPS2Nub.kext` | `com.yourcompany.driver.AppleACPIPS2Nub` | `1.0.0d1` | `x86_64,i386` | `UNSPECIFIED` | `6de69141d208a3dbbf5f35fc25fd6d5a9ad3193ec95ff59ad4aa96a028193054` | STATIC_I386_PASS; RUNTIME_NOT_TESTED |
| `VoodooPS2Controller.kext` | `org.voodoo.driver.PS2Controller` | `1.1.0` | `i386,x86_64` | `UNSPECIFIED` | `85e484df58cc24224ca2615d7565641bbe5abfab0f28dc30986fe4f2aa88f199` | STATIC_I386_PASS; RUNTIME_NOT_TESTED |
| `VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Keyboard.kext` | `org.voodoo.driver.PS2Keyboard` | `1.1.0` | `x86_64,i386,ppc` | `UNSPECIFIED` | `6b8d9d7b74b864d149671d6d7dadfa1591e572144e0aa714cd9b975f7868d6a5` | STATIC_I386_PASS; RUNTIME_NOT_TESTED |
| `VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Mouse.kext` | `org.voodoo.driver.PS2Mouse` | `1.2.0` | `x86_64,i386` | `UNSPECIFIED` | `59f9a55be0aab1db393d77fef1b387af78bf3b44f3d1d120a2a58900d39e7c93` | STATIC_I386_PASS; RUNTIME_NOT_TESTED |
| `VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Trackpad.kext` | `org.voodoo.driver.PS2Trackpad` | `1.1.0` | `x86_64,i386` | `UNSPECIFIED` | `3ebbbbf9474dcacbfe2b0a809fab0ce5800cdb36633ccdb20c8743b4c777ea3b` | STATIC_I386_PASS; RUNTIME_NOT_TESTED |
| `fakesmc.kext` | `org.netkas.fakesmc` | `1` | `i386,x86_64` | `UNSPECIFIED` | `0d8495c2770d95f837e901c8f7061f1c3cce1f390a3d141023edfb6c4475cb1c` | STATIC_I386_PASS; RUNTIME_NOT_TESTED |

## Kernel artifacts

Vanilla mode: no kernel was copied or replaced; the retail source remains unmodified.

## Known unresolved hardware

BCM5787M Ethernet, exact Wi-Fi PCI ID, ALC268 codec confirmation, battery ACPI,
Bluetooth, FireWire, webcam and modem remain post-install/runtime work.

## Validation

- EFI references/dependencies: PASS
- ocvalidate 1.0.7: PASS
- plistlib (7 files): PASS

- bash -n: PASS
- shellcheck: PASS
- shfmt -d: NOT AVAILABLE (optional)
