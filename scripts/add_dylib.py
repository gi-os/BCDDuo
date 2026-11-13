#!/usr/bin/env python3
"""Usage: add_dylib.py <thin 64-bit Mach-O> <install name>

Adds an LC_LOAD_WEAK_DYLIB for <install name> in the header's spare room, so the binary loads that
library at launch (weak: the app still starts if the library is missing). Sign the binary afterwards.
"""
import struct
import sys

LC_SEGMENT_64, LC_LOAD_WEAK_DYLIB, HEADER = 0x19, 0x80000018, 32
path, name = sys.argv[1], sys.argv[2].encode()
data = bytearray(open(path, "rb").read())
if struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
    sys.exit(f"{path}: not a thin 64-bit Mach-O")
ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)

first_section = len(data)
offset = HEADER
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, offset)
    if name in data[offset:offset + size] and cmd != LC_SEGMENT_64:
        sys.exit(f"{path}: already loads {name.decode()}")
    if cmd == LC_SEGMENT_64:
        for i in range(struct.unpack_from("<I", data, offset + 64)[0]):
            section_offset = struct.unpack_from("<I", data, offset + 72 + 80 * i + 48)[0]
            if section_offset:
                first_section = min(first_section, section_offset)
    offset += size

size = (24 + len(name) + 1 + 7) & ~7
end = HEADER + sizeofcmds
if end + size > first_section or any(data[end:end + size]):
    sys.exit(f"{path}: no room for another load command")
data[end:end + size] = struct.pack("<IIIIII", LC_LOAD_WEAK_DYLIB, size, 24, 2, 0x10000, 0x10000) + name.ljust(size - 24, b"\0")
struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + size)
open(path, "wb").write(data)
print(f"{path}: loads {name.decode()}")
