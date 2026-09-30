#!/usr/bin/env python3
"""Dump per-slice arch + fixup-related load commands of a Mach-O (thin or fat)."""
import struct
import sys

CMDS = {
    0x80000022: 'LC_DYLD_INFO_ONLY', 0x22: 'LC_DYLD_INFO',
    0x80000034: 'LC_DYLD_CHAINED_FIXUPS', 0x26: 'LC_DYLD_EXPORTS_TRIE',
    0x1d: 'LC_CODE_SIGNATURE', 0x80000028: 'LC_BUILD_VERSION',
    0x25: 'LC_VERSION_MIN_IPHONEOS', 0x80000036: 'LC_FILESET_ENTRY',
}


def dump_slice(d, off, idx):
    magic, ct, cs, ft, ncmds = struct.unpack_from('<IiiII', d, off)
    kind = {0xFEEDFACF: 'MH_MAGIC_64', 0xCAFEBABE: 'FAT'}.get(magic, hex(magic))
    print(f'  slice{idx} @ {off:#x}: magic={kind} cputype={ct:#x} cpusub={cs:#x} filetype={ft}')
    if magic != 0xFEEDFACF:
        return
    o = off + 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, o)
        name = CMDS.get(cmd, f'cmd_{cmd:#x}')
        extra = ''
        if cmd in (0x80000022, 0x22):
            ro, rn = struct.unpack_from('<II', d, o + 8)
            extra = f' rebase_off={ro:#x} rebase_size={rn:#x}'
        elif cmd == 0x80000034:
            extra = ' (chained fixups present)'
        print(f'    {name}{extra}')
        o += size


def main(path):
    d = open(path, 'rb').read()
    print(f'== {path} ({len(d)} bytes)')
    magic, n = struct.unpack_from('>II', d, 0)
    if magic == 0xCAFEBABE:
        for i in range(n):
            ct, cs, off, sz, al = struct.unpack_from('>iiIII', d, 8 + i * 20)
            dump_slice(d, off, i)
    elif magic == 0xFEEDFACF:
        dump_slice(d, 0, 0)
    else:
        print(f'  unknown magic {magic:#x}')


for p in sys.argv[1:]:
    main(p)
