#!/usr/bin/env bash
# Build pipeline for hello-kernel.
#
# Steps, in order:
#   1. Compile main.cpp into a freestanding object file.
#   2. Link the object file into a higher-half kernel ELF.
#   3. Fetch Limine's prebuilt bootloader (one-time clone).
#   4. Stage the ISO directory tree.
#   5. Pack the staged tree into a hybrid BIOS+UEFI bootable ISO.
#   6. Patch the BIOS boot record into the ISO.
#
# All generated files land in build/. Re-run this script after editing
# main.cpp, linker.ld, or limine.conf. Wipe everything with: rm -rf build

set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build

# ---------------------------------------------------------------------------
# 1. Compile main.cpp -> build/main.o
# ---------------------------------------------------------------------------
clang++ --target=x86_64-elf \
    -ffreestanding -fno-exceptions -fno-rtti \
    -fno-stack-protector -mno-red-zone -mcmodel=kernel \
    -Wall -Wextra \
    -c main.cpp -o build/main.o

# ---------------------------------------------------------------------------
# 2. Link build/main.o -> build/kernel.elf using linker.ld
# ---------------------------------------------------------------------------
ld.lld -nostdlib -static -T linker.ld -o build/kernel.elf build/main.o

# ---------------------------------------------------------------------------
# 3. Fetch Limine's prebuilt bootloader binaries (one-time).
# ---------------------------------------------------------------------------
if [ ! -d build/limine ]; then
    git clone https://github.com/limine-bootloader/limine.git \
        --branch=v9.x-binary --depth=1 build/limine
    make -C build/limine
fi

# ---------------------------------------------------------------------------
# 4. Stage the ISO tree at build/iso_root/.
#    Wipe and rebuild so stale files don't leak between runs.
# ---------------------------------------------------------------------------
rm -rf build/iso_root
mkdir -p build/iso_root/boot/limine build/iso_root/EFI/BOOT

cp build/kernel.elf  build/iso_root/boot/
cp limine.conf       build/iso_root/
cp build/limine/limine-bios.sys \
   build/limine/limine-bios-cd.bin \
   build/limine/limine-uefi-cd.bin   build/iso_root/boot/limine/
cp build/limine/BOOTX64.EFI          build/iso_root/EFI/BOOT/

# ---------------------------------------------------------------------------
# 5. Build the hybrid (BIOS + UEFI) bootable ISO.
# ---------------------------------------------------------------------------
xorriso -as mkisofs \
    -R -r -J \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
    -apm-block-size 2048 \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    build/iso_root -o build/hello-kernel.iso

# ---------------------------------------------------------------------------
# 6. Embed the Limine BIOS bootloader stage into the ISO.
#    UEFI doesn't need this step; UEFI loads BOOTX64.EFI directly.
# ---------------------------------------------------------------------------
./build/limine/limine bios-install build/hello-kernel.iso

echo
echo "Built build/hello-kernel.iso"
