#!/bin/bash
# Build the shim for the Moto G Play 2024 (fogona, SM6225) and wrap it in a boot.img header v4.
# No DTB is packed: the bootloader hands the shim the live FDT. Flash nothing: use `fastboot boot`.
set -euo pipefail
cd "$(dirname "$0")"
CC=${CC:-aarch64-linux-gnu-gcc}
OBJCOPY=${OBJCOPY:-aarch64-linux-gnu-objcopy}
READELF=${READELF:-aarch64-linux-gnu-readelf}
NM=${NM:-aarch64-linux-gnu-nm}
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$($NM out/shim.elf | awk '$3=="_end"{print strtonum("0x"$1)}')
truncate -s "$size" out/Image
# Optional $1 = xnu payload (tools/mkpayload.py) packed as the boot ramdisk.
# Without it the image is the diagnostics-only shim (no ramdisk at all).
RD=()
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
	RD=(--ramdisk out/ramdisk.bin)
fi
python3 ../tools/mkbootv4.py --kernel out/Image "${RD[@]}" \
	--cmdline "console=null" -o out/shim-boot-v4.img
# Host render of the console layout.
gcc -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test
ls -l out/Image out/shim-boot-v4.img
