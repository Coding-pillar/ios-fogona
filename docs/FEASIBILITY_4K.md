# Feasibility: XNU on a CPU without the 16K translation granule (Moto G Play 2024, "fogona")

Status: desk study of Apple's published XNU sources (xnu-4903.270.47 = macOS 10.14.6 / iOS 12 era, and
xnu-8796.141.3 = what ios-sweet builds). Nothing here has been built or run yet.

## The problem

The boot CPU is a Qualcomm Kryo "Silver" (MIDR 0x51AF8014, Cortex-A53 class, ARMv8.0).
`ID_AA64MMFR0_EL1 = 0x1122`: TGran16 = 0 (16K translation granule NOT implemented), TGran4 = 0 and
TGran64 = 0 (both implemented). ios-sweet sets `__ARM_16K_PG__` (xnu/patches/0004) and the shim builds 16K
tables (shim/mmu.c), so neither can run here.

## Finding 1: XNU separates hardware page size from VM page size (promising)

In both source trees:

- `ARM_PGSHIFT` (hardware granule) is 14 only if `__ARM_16K_PG__` is defined, otherwise 12
  (osfmk/arm64/proc_reg.h). `__ARM_16K_PG__` comes from the per-SoC header in pexpert/pexpert/arm64/
  (e.g. H13.h; ios-sweet's SWEET header copies this). A machine config that simply does not define it
  gives a 4K-granule kernel.
- `PAGE_SHIFT` (the VM page size) is a runtime variable (`PAGE_SHIFT_CONST`) on non-16K builds
  (osfmk/mach/arm/vm_param.h). `osfmk/arm/arm_init.c` picks it at boot: 16K when RAM > 1 GiB, else the
  hardware size. The comment says "4KB for H6/H7, 16KB for H8+" (H6/H7 = A7/A8): those iPhones ran 4K
  hardware pages while presenting 16K pages to software. Apple DTS confirms apps see 16 KiB on all 64-bit
  iOS devices.
- `PAGE_RATIO = (1 << PAGE_SHIFT) >> ARM_PGSHIFT` (4 for 16K VM over 4K hardware). The pmap handles it,
  e.g. `write_pte_fast()` writes four PTEs per VM page (osfmk/arm/pmap/pmap.c in 8796, osfmk/arm/pmap.c
  in 4903). 8796 keeps `pmap_pt_attr_4k` and 4K branches in proc_reg.h (19 `__ARM_16K_PG__` sites),
  pmap.c (10) and tlb.h (4). Code in arm_vm_init.c is written in `ARM_PGBYTES` vs `PAGE_SIZE` terms.
- Caveat: iOS 16 only supports A11 and later (all 16K hardware), so the 4K branches in 8796 are
  probably untested upstream and may have bit-rotted. The old A7/A8 platform headers (typhoon.h etc.)
  exist only in 4903. Unproven until a 4K 8796 kernel compiles and boots.

Conclusion: the page size is not a hard blocker in principle. The userland still sees 16K pages.

## Finding 2: what ios-sweet code must change for a 4K-granule build

Small surface, as far as grep shows (added lines mentioning page size / 16K / granule):

| Area | Work |
| --- | --- |
| shim/mmu.c | Rewrite for 4K granule: TCR.TG0 = 4K, 36-bit VA (T0SZ 28) starts at level 1, 2 MiB blocks instead of 32 MiB. Small. |
| xnu/patches/0004 (machine config) | Drop `__ARM_16K_PG__`; also drop `__ARM_PAN_AVAILABLE__` (PAN is ARMv8.1+, A53/A73 are v8.0); re-check crypto extension define. |
| 0010 / 0011 / 0012 (early FB, physmap padding, keep console after TTBR0) | Assume 16K-granule block maps (32 MiB). Need rework for 4K tables. |
| 0046 / 0058 / 0060 | Mention 16K in comments/size math; likely trivial. |
| tools/mkpayload.py virt_base | Comment ties 32 MiB to 16K L2 blocks; recheck. |
| 0065 (SMP) / 0078 | Khaje MPIDRs (Aff0 = core, Aff1 = cluster) differ from sweet; 4 big + 4 little cores, not 6+2. |
| Drivers | Touch is SPI (Novatek/Chipone/Ilitek), PMIC is PM6125, display 720x1600; not page-size related. |

## Finding 3: bigger unknown, instruction-set baseline

Kryo Silver/Gold here are ARMv8.0 (no LSE atomics, no PAN, no ARMv8.2 extras). sweet's A55/A76 are ARMv8.2.
The iPhone X userland (iOS 16.7.16, built for A11 = ARMv8.2) may use instructions these cores do not have
(LSE atomics `cas`/`ldadd`/`swp`, FP16, ...), which would SIGILL. Not checked: needs the IPSW's dyld shared
cache. iOS 12 userland targets A7/A8 (ARMv8.0), so it matches this CPU, at the price of an older kernel.

Cheap checks:
1. On the phone: `grep -m1 Features /proc/cpuinfo` (look for `atomics`, `asimdhp`, `fphp`, `aes`, `sha2`).
2. On a PC with the IPSW: scan the iPhone X dyld shared cache for LSE opcodes (e.g. with `ipsw dyld`
   disassembly or `llvm-objdump` over libsystem_pthread / libdispatch / libobjc) and count hits.

## Two routes

A. xnu-8796 (iOS 16): keep ios-sweet's patch series. Needs: 4K machine config, shim mmu rewrite,
   rework of 0010-0012 and 0065, plus Khaje drivers. Risk: bit-rotted 4K code in 8796, and ARMv8.2
   instructions in the iOS 16 userland (Finding 3).
B. xnu-4903 (iOS 12 / iPhone 6-5s class userland): matches the CPU's ISA and keeps the real 4K-hardware
   code path alive upstream. Risk: all ~80 ios-sweet patches are written against 8796 and must be
   redone; blacktop/darwin-xnu-build documents 12.5-14.3 only (xnu-4903 is macOS 10.14), so the build
   toolchain is its own project; iOS 12 userland (APFS root, no cryptex) must be converted to the HFS+ root
   the kernel mounts.

Mixed (8796 kernel + iOS 12 userland) is unlikely to work: kernel/userland ABI differs.

## Suggested order (cheapest decisive step first)

1. Phone feature check (above) and IPSW LSE scan: decides whether route A can be ruled out for userland reasons.
2. Compile xnu-8796 with a Khaje 4K machine config in CI (no phone): measures how rotted the 4K path is.
3. Shim 4K MMU + framebuffer console: first XNU log lines on screen.
4. Only then drivers (SPI touch, PMIC buttons) and storage.

Sources: https://github.com/apple-oss-distributions/xnu (tags xnu-4903.270.47, xnu-8796.141.3),
https://developer.apple.com/forums/thread/47532
