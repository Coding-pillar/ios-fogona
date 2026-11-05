#!/usr/bin/env python3
"""Pack a kernel (+ optional ramdisk) into an Android boot.img header v4.

Header v4 (Android 12+ GKI devices such as the Moto G Play 2024 'fogona'):
no load addresses and no DTB in boot.img (the DTB lives in vendor_boot, and the
bootloader passes the merged live FDT to the kernel). Layout, 4096-byte pages:

    header (1584 bytes, padded) | kernel | ramdisk | boot signature (0)

Usage: mkbootv4.py --kernel Image [--ramdisk rd.bin] [--cmdline STR] -o OUT.img
Verified field-for-field against Motorola's stock fogona boot.img header.
"""
import argparse, struct

PAGE = 4096
HEADER_SIZE = 1584


def pad(b):
    return b + b'\0' * (-len(b) % PAGE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kernel', required=True)
    ap.add_argument('--ramdisk')
    ap.add_argument('--cmdline', default='console=null')
    ap.add_argument('--os_version', type=lambda x: int(x, 0), default=0)
    ap.add_argument('-o', '--out', required=True)
    a = ap.parse_args()
    kernel = open(a.kernel, 'rb').read()
    ramdisk = open(a.ramdisk, 'rb').read() if a.ramdisk else b''
    cmd = a.cmdline.encode()
    if len(cmd) > 1535:
        raise SystemExit('cmdline too long for boot header v4 (1536 bytes)')
    hdr = b'ANDROID!'
    hdr += struct.pack('<5I', len(kernel), len(ramdisk), a.os_version, HEADER_SIZE, 0)
    hdr += b'\0' * 12                      # reserved[1..3]
    hdr += struct.pack('<I', 4)            # header_version
    hdr += cmd.ljust(1536, b'\0')
    hdr += struct.pack('<I', 0)            # signature_size
    assert len(hdr) == HEADER_SIZE, len(hdr)
    open(a.out, 'wb').write(pad(hdr) + pad(kernel) + pad(ramdisk))


if __name__ == '__main__':
    main()
