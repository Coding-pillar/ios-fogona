#!/usr/bin/env python3
"""Scan arm64 Mach-O files for ARMv8.1 LSE atomic instructions (CAS*, SWP*, LD<op>*, ST<op>*).

Why: the Moto G Play 2024 (Snapdragon 680, Kryo Silver/Gold, ARMv8.0) has no LSE atomics
(/proc/cpuinfo Features: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid). If iOS userland
executes one of these it dies with SIGILL, unless the kernel emulates them.

Usage:  scan-lse.py PATH [PATH...]        files or directories (walked recursively)
        scan-lse.py --top 40 DIR          show the 40 files with most hits

Feed it standalone Mach-O files, e.g. the dylibs extracted from the iPhone X dyld shared cache
(`ipsw dyld split <dyld_shared_cache> OUTDIR`) and the executables of the iOS root.
Only each file's __TEXT,__text section is scanned (jump tables / literal pools can cause a few
false positives; read the counts as orders of magnitude, not exact numbers).
Fat files: the arm64 slice (cputype 0x0100000c) is used; arm64e slices are scanned too.
"""
import argparse, collections, os, struct, sys

try:
    import numpy as np  # optional, ~50x faster
except ImportError:
    np = None

CPU_TYPE_ARM64 = 0x0100000C
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
LC_SEGMENT_64 = 0x19

LD_OPS = ['ADD', 'CLR', 'EOR', 'SET', 'SMAX', 'SMIN', 'UMAX', 'UMIN']


def classify(w):
    """Return a short name if w is an LSE instruction, else None."""
    # Atomic memory operations: size 111 0 00 A R 1 Rs o3 opc 00 Rn Rt
    if (w & 0x3F200C00) == 0x38200000:
        o3 = (w >> 15) & 1
        opc = (w >> 12) & 7
        rt = w & 31
        if o3 == 0:
            return ('ST' if rt == 31 else 'LD') + LD_OPS[opc]
        if opc == 0:
            return 'SWP'
        return None  # LDAPR (ARMv8.3) and newer encodings: not counted here
    # CAS/CASA/CASL/CASAL: size 0010001 L 1 Rs o0 11111 Rn Rt
    if (w & 0x3FA07C00) == 0x08A07C00:
        return 'CAS'
    # CASP
    if (w & 0xBFA07C00) == 0x08207C00:
        return 'CASP'
    return None


def text_section(buf, base):
    """Yield (offset, size) of __TEXT,__text in the thin Mach-O starting at buf[base:]."""
    magic, = struct.unpack_from('<I', buf, base)
    if magic != MH_MAGIC_64:
        return
    cputype, _, _, ncmds, _ = struct.unpack_from('<iIIII', buf, base + 4)
    if cputype != CPU_TYPE_ARM64:
        return
    off = base + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', buf, off)
        if cmd == LC_SEGMENT_64:
            segname = buf[off + 8:off + 24].split(b'\0')[0]
            nsects, = struct.unpack_from('<I', buf, off + 64)
            if segname == b'__TEXT':
                so = off + 72
                for _ in range(nsects):
                    sect = buf[so:so + 16].split(b'\0')[0]
                    size, = struct.unpack_from('<Q', buf, so + 40)
                    foff, = struct.unpack_from('<I', buf, so + 48)
                    if sect == b'__text' and foff:
                        yield foff, size  # relative to the start of the thin slice
                    so += 80
        off += cmdsize


def thin_slices(buf):
    magic_be, = struct.unpack_from('>I', buf, 0)
    if magic_be == FAT_MAGIC:
        n, = struct.unpack_from('>I', buf, 4)
        for i in range(n):
            cputype, _, offset, size, _ = struct.unpack_from('>iiIII', buf, 8 + 20 * i)
            if cputype == CPU_TYPE_ARM64:
                yield offset
    else:
        yield 0


def scan_file(path):
    try:
        with open(path, 'rb') as f:
            buf = f.read()
    except OSError:
        return None
    if len(buf) < 32:
        return None
    counts = collections.Counter()
    total_words = 0
    found = False
    for base in thin_slices(buf):
        for foff, size in text_section(buf, base):
            found = True
            start = base + foff
            end = min(start + size, len(buf)) & ~3
            n = (end - start) // 4
            total_words += n
            if np is not None:
                arr = np.frombuffer(buf, dtype='<u4', count=n, offset=start)
                hit = ((arr & 0x3F200C00) == 0x38200000) | ((arr & 0x3FA07C00) == 0x08A07C00) | \
                      ((arr & 0xBFA07C00) == 0x08207C00)
                words_iter = arr[hit].tolist()
            else:
                words_iter = (w for w in struct.unpack_from('<%dI' % n, buf, start)
                              if (w & 0x38000000) in (0x08000000, 0x38000000))
            for w in words_iter:
                name = classify(w)
                if name:
                    counts[name] += 1
    return (counts, total_words) if found else None


def walk(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for fn in files:
                    yield os.path.join(root, fn)
        else:
            yield p


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('paths', nargs='+')
    ap.add_argument('--top', type=int, default=20, help='files with most hits to list')
    a = ap.parse_args()

    per_file, grand, scanned, words = [], collections.Counter(), 0, 0
    for path in walk(a.paths):
        r = scan_file(path)
        if not r:
            continue
        counts, nwords = r
        scanned += 1
        words += nwords
        grand.update(counts)
        if counts:
            per_file.append((sum(counts.values()), path, counts))

    per_file.sort(reverse=True)
    print('Mach-O files scanned : %d   (%d instructions)' % (scanned, words))
    print('Files with LSE hits  : %d' % len(per_file))
    print('Total LSE hits       : %d' % sum(grand.values()))
    if grand:
        print('By kind              : ' + ', '.join('%s=%d' % kv for kv in grand.most_common()))
        print('\nTop files:')
        for n, path, c in per_file[:a.top]:
            print('  %8d  %s' % (n, path))
    else:
        print('No LSE atomics found: userland looks ARMv8.0-safe for atomics.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
