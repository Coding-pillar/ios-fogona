# Porting ios-sweet to the Moto G Play 2024 ("fogona", Snapdragon 680 / SM6225 "Khaje")

Branch `khaje-fogona`. Values come from the stock firmware (vendor_boot DTBs, dtbo)
and the phone's live FDT + `/proc/iomem`. Everything marked TODO is untested.

## sweet -> fogona

| Item | sweet (SM7150) | fogona (Khaje) | Where |
| --- | --- | --- | --- |
| UFS host | 0x01d84000 | 0x04804000 (PHY 0x4807000, ICE 0x4810000) | shim/ufs.c, tools/mkadt.py |
| GICD / GICR | 0x17a00000 / 0x17a60000 | 0x0f200000 / 0x0f300000 (stride 0x20000, 8 PEs) | shim/shim.c, tools/mkadt.py |
| Framebuffer | 0x9c000000, 1080x2400 | 0x5c000000 (0xf00000), 720x1600 (stride TODO verify) | shim/console.h, mmu.h, tools/mkadt.py |
| PSHOLD | 0x0c264000 | 0x0440b000 | shim/shim.c |
| IMEM restart_reason | 0x146aa65c | 0x0c12565c | shim/shim.c |
| RAM | 0x100000000 + 0xfcc00000 | banks 0x40000000+0x3dd00000, 0x80000000+0x40000000, 0xc0000000+0x80000000; kernel RAM = upper 2 GiB | tools/mkadt.py |
| MPIDRs | Aff1 = core (0x000..0x700) | Aff0 = core, Aff1 = cluster: 0x0-0x3, 0x100-0x103 | shim/shim.c (done); XNU patches 0065/0078 TODO |
| Boot image | header v2 + DTB | header v4 (DTB lives in vendor_boot) | shim/build-khaje.sh, tools/mkbootv4.py |
| Touch | Goodix I2C | SPI (spi@4a80000): Novatek / Chipone / Ilitek | patches 0060/0063 TODO |
| PMIC | PM6150 | PM6125 | patch 0060 TODO |

Unchanged: GICv3 Group 1 IRQ, PSCI over `smc`, 19.2 MHz timer, vtimer INTID 19 / ptimer 18.

## Milestone 1: does the shim run? (nothing is flashed)

    cd shim
    ./build-khaje.sh                 # needs aarch64-linux-gnu-gcc; also runs the host console test
    fastboot boot out/shim-boot-v4.img

The shim draws diagnostics into the splash framebuffer. If the screen stays
black or the picture is skewed, the framebuffer address, stride or pixel format
differs from the defaults: check the first lines it prints and `FB_*` in
console.h. Hold Power + Volume down to leave. `fastboot boot` with a v4 image
needs bootloader support and the phone's own vendor_boot: untested.

## TODO before XNU boots

- XNU patches 0010/0012/0046/0058/0060/0061 still hard-code 0x9c000000 and 1080x2400.
- iPhone X logical panel (1125x2436) is cropped on sweet; a 720x1600 panel needs scaling.
- SMP: patches 0065/0078 assume sweet's MPIDR layout. Start with `cpus=1`.
- Root storage: ios-sweet formats `userdata`. Keep your GSI intact by booting from RAM or a separate target first.
- Touch (SPI) and buttons (PM6125) drivers.
