# Snow Leopard boot path for Acer Aspire 4310

This project now has a dedicated Snow Leopard convenience wrapper. It keeps the
existing Leopard workflow intact and makes Snow Leopard the quickest alternate
path for testing the Aspire 4310 when Darwin 9 stalls during early IOKit startup.

## Recommended profile

Use the default profile first:

- Mac OS X Snow Leopard 10.6.x retail installer
- IA32 OpenDuet + IA32 OpenCore
- `KernelArch=i386`
- `KernelCache=Auto`
- `MacBook2,1`
- `FixupAppleEfiImages=true`
- `RebuildAppleMemoryMap=true` (`--runtime modern`)
- `DummyPowerManagement=true`
- duplicate Phoenix MADT dropped
- diagnostic boot arguments: `-v keepsyms=1 debug=0x108 io=0x20007f`
- minimal legacy SMC + PS/2 kext set

The i386 kernel is intentional for Intel GMA950. Snow Leopard may still run
64-bit userland applications on a 64-bit-capable CPU even when XNU itself is i386.

## Experimental 64-bit kernel profile

Pass `--x64` to the wrapper to build:

- X64 OpenDuet + X64 OpenCore
- `KernelArch=x86_64`
- `arch=x86_64` in boot arguments
- `HfsPlusLegacy.efi`
- SMC-only injected kext set for the first test

The wrapper rejects the experimental build if an enabled executable kext does not
contain an `x86_64` slice. This mode is not the default because GMA950 is much
more reliable with 32-bit kernelspace on Snow Leopard-era systems.

## Prepare on an Intel Mac

```bash
git clone https://github.com/IlyaBOT/Acer-Aspire-4310-MacOS-X-Leopard-Install-Kit.git
cd Acer-Aspire-4310-MacOS-X-Leopard-Install-Kit
chmod +x prepare_aspire4310_macos.sh scripts/prepare_snowleopard_usb.sh

./prepare_aspire4310_macos.sh --doctor
./scripts/prepare_snowleopard_usb.sh --download
```

Provide your own retail Snow Leopard image as either:

```text
input/SnowLeopard-Retail.iso
input/SnowLeopard-Retail.dmg
```

The project intentionally does not download a retail Mac OS X installer.

## Build without touching a USB drive

Recommended profile:

```bash
./scripts/prepare_snowleopard_usb.sh --build
```

Experimental x86_64 profile:

```bash
./scripts/prepare_snowleopard_usb.sh --build --x64
```

## Create a fresh installer USB

List disks first:

```bash
./scripts/prepare_snowleopard_usb.sh --list-disks
```

Then replace `/dev/diskX` with the whole-disk identifier of the USB drive:

```bash
./scripts/prepare_snowleopard_usb.sh \
  --make-usb \
  --disk /dev/diskX \
  --retail "$PWD/input/SnowLeopard-Retail.iso"
```

The underlying builder will show the target disk and require an exact destructive
confirmation before repartitioning it.

Verify the finished drive:

```bash
./scripts/prepare_snowleopard_usb.sh --verify --disk /dev/diskX
```

## Experimental x86_64 USB

Only after the recommended i386-kernel attempt has been tested:

```bash
./scripts/prepare_snowleopard_usb.sh \
  --make-usb \
  --x64 \
  --disk /dev/diskX \
  --retail "$PWD/input/SnowLeopard-Retail.iso"
```

If this boots further than the i386 profile, keep the result for comparison. If
it reaches graphics initialization and produces corruption or a black screen,
return to the i386 kernel profile before debugging GMA950.

## First boot on the Acer

1. Enable USB boot/F12 boot menu in the Phoenix BIOS.
2. Boot the USB device through OpenDuet/OpenCore.
3. Select the Snow Leopard installer volume.
4. Keep the first attempt on native SATA and the minimal kext set.
5. Photograph or capture the final verbose lines if the machine stalls.
6. If it reaches `Still waiting for root device`, rebuild with the project's SATA
   injected fallback rather than changing unrelated quirks.
7. After installation, boot the installed system through the USB OpenCore first.
8. Update to the official 10.6.8 Combo Update before heavy post-install driver work.
