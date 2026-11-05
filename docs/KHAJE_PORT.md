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

### Result (2026-10-27, from a photo of the screen)

- `fastboot boot out/shim-boot-v4.img` works on the stock bootloader: header v4 is accepted, the shim runs.
- Framebuffer 0x5c000000 confirmed: text is drawn straight with the right colours, so stride 720*4 and a8r8g8b8 are right.
- Console was clipped on the right (it was laid out for 1080 px). Fixed: font scale 2, wrapping, top margin below the camera hole.
- UFS host at 0x04804000 works with the unchanged driver: HCI ver 0x300, host enabled, TUR/CAP/READ ok, MBR 0xAA55, GPT found (3 entries) on LUN 0.
- LUN 0 is a small unit (lastlba 0xFFF, 3 GPT entries). From the phone's `/dev/block/by-name` (sdX = LUN X-a): boot_a, init_boot_a, vendor_boot_a are on sdd (LUN 3); super (sde25) and userdata (sde27) are on sde (LUN 4). The UFS probe now scans LUN 0-5 and lists the big partitions of LUN 4 (`-DUFS_SHOW_LUN=n` to change).
- An SD card is present (mmcblk1p1, sdhci@4784000), a possible home for the iOS root instead of userdata (needs an MMC driver in XNU).
- Not yet run: MMU, PSCI, GIC/timer and SMP checks (build with `EXTRA_CFLAGS=-DSHIM_DIAG ./build-khaje.sh`; this replaces the UFS probe).

### Result 2 (UFS scan + diagnostics hang)

- UFS scan (LUN = sdX letter - 'a'): LUN0 16 MiB, LUN1/2 8 MiB (3 GPT entries each), LUN3 ~0.9 GiB (25 entries, boot/vendor_boot), LUN4 ~57.7 GiB (28 entries: metadata 64 MiB, super 6400 MiB, userdata 52397 MiB, ramdump 128 MiB), LUN5 = copy of LUN3 layout.
- userdata reads as fs "other": probably dm-default-key metadata encryption, not an empty partition.
- `-DSHIM_DIAG` (old build) hung silently at `mmu_enable`. Cause confirmed by the pre-MMU check on the phone: MIDR 0x51AF8014 (Qualcomm Kryo "Silver", Cortex-A53 class, boot CPU mpidr 0x80000000) and ID_AA64MMFR0_EL1 = 0x1122, i.e. **TGran16 = 0 (16K granule NOT supported)**; TGran4 = 0 and TGran64 = 0 mean 4K and 64K ARE supported. The shim's TCR (TG0 = 16K) is invalid on this CPU. sweet's A55/A76 cores support 16K.
- With the MMU step skipped the rest of the diagnostics run: DTB handed over at 0x44C00000 (valid FDT), PSCI 1.1 / SMCCC 1.1, GICv3 Group 1 delivery works (virtual timer INTID 19: 30 IRQs in 300 ms; SGI to self: 10 IRQs), same as sweet. SMP (CPU_ON with the new MPIDRs) not yet exercised in the diag path.
- Consequence: XNU as built by ios-sweet (16K pages, iOS 16 userland built for 16K) cannot run on this SoC. A 4K-granule XNU is a different project, not a port of this branch. Notes (unverified beyond the header): xnu-4903's arm64 `proc_reg.h` selects the 4K translation granule (ARM_PGSHIFT 12, TCR_TG0 4K) whenever `__ARM_16K_PG__` is not defined, so the source can target CPUs without 16K support. Apple DTS says user-visible page size is 16 KiB on all 64-bit iOS devices, so whether a 4K-hardware-page build can still present 16K VM pages (needed by the iOS userland) is an open question to check in pmap/VM code. Earlier claim that A7/A8 iPhones used 4K user pages was wrong: they used 4K hardware pages with 16K VM pages (see docs/FEASIBILITY_4K.md).

## TODO before XNU boots

- XNU patches 0010/0012/0046/0058/0060/0061 still hard-code 0x9c000000 and 1080x2400.
- iPhone X logical panel (1125x2436) is cropped on sweet; a 720x1600 panel needs scaling.
- SMP: patches 0065/0078 assume sweet's MPIDR layout. Start with `cpus=1`.
- Root storage: ios-sweet formats `userdata`. Keep your GSI intact by booting from RAM or a separate target first.
- Touch (SPI) and buttons (PM6125) drivers.
