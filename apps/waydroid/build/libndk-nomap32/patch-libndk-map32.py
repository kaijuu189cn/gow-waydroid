#!/usr/bin/env python3
"""Patch Android 17 berberis libndk_translation.so to drop MAP_32BIT.

WHY
---
Honor of Kings (com.tencent.tmgp.sgame) is a pure arm64 Unity/IL2CPP title and
runs through Android 17's ARM translator (berberis, ro.berberis.mode=two-gear).
The game aborts a few seconds to a few minutes after launch, always from the
UnityMain thread, with:

    Abort message: 'frameworks/libs/binary_translation/base/mmap_posix.cc:128:
                     CHECK failed: 0xffffffffffffffff != 0xffffffffffffffff'

Backtrace (tombstone, symbolised):

    #04 berberis::MmapImplOrDie(berberis::MmapImplArgs)
    #05 berberis::ExecRegionAnonymousFactory::Create(unsigned long)
    #06 berberis::CodePool<berberis::ExecRegionAnonymousFactory>::Add(MachineCode*)
    #07 berberis::TryLiteTranslateAndInstallRegion(...)
    #08 berberis::TranslateRegion<(anonymous namespace)::TranslationGear 0>(...)

MmapImplOrDie calls mmap() and asserts on MAP_FAILED. mmap() fails because the
caller is forced into the low 2 GB of the address space (MAP_32BIT) and that
window is exhausted: each 4 MB translated-code region consumes a slot there,
and the tombstones show 197-245 regions all living between 0x46000000 and
0x7fdfffff (1120 MB .. 2045 MB) -- i.e. right up against the 2048 MB ceiling.

Note this is NOT a system memory shortage. The host still had 19 GB free when
the crash was captured; only the 32-bit window ran out.

THE FIX
-------
MmapImplOrDie builds its mmap flags like this:

    7a3daa: testb  $0x1,0x38(%rbp)     ; honour MAP_32BIT request?
    7a3dae: je     7a3dba
    7a3db0: mov    %ecx,%eax
    7a3db2: and    $0x10,%eax          ; MAP_FIXED already set?
    7a3db5: jne    7a3df1              ; -> separate fixed-address path
    7a3db7: or     $0x40,%ecx          ; <-- MAP_32BIT (0x40 on Linux x86-64)
    7a3dba: call   mmap@plt
    7a3dbf: cmp    $0xffffffffffffffff,%rax
    7a3dc3: je     7a3dc7              ; MAP_FAILED -> __android_log_assert

`or $0x40,%ecx` (bytes 83 c9 40) is replaced with three NOPs (90 90 90). Same
length, so no instruction boundaries shift. mmap() then has the whole 47-bit
address space to work with and the code pool keeps growing instead of aborting.

This is deliberately NOT the same edit as the earlier attempt, which zeroed the
`movl $0x1,-0x30(%rbp)` flag at 0x7aaddc (file offset 8039900). That field
selects a whole MmapImplArgs code path, so clearing it broke translator init and
the container failed to boot. Touching only the flag-OR keeps both paths intact.

OFFSETS
-------
berberis 16.0.0 x86_64 (LineageOS 24.0 / Android 17, libndk_translation.so,
8,743,696 bytes, BuildId 125abe4474cee6c228658bad2f793726).

This ELF is PIE with .text vaddr == file offset, verified by locating the
instruction that the tombstone PC (MmapImplOrDie+96 = 0x7a3df0) points at.

    file 0x7a3db7   83 c9 40   or $0x40,%ecx   ->   90 90 90

Verify after patching:

    objdump -d --start-address=0x7a3db0 --stop-address=0x7a3dc0 <file>

Deploy: the system image is erofs (read-only), so the library cannot be
replaced inside system.img. Put the patched file in the Waydroid overlay and
enable it:

    /var/lib/waydroid/overlay/system/lib64/libndk_translation.so
    waydroid.cfg:  mount_overlays = True

The overlay is applied when the *session* mounts the rootfs, so a full session
restart is required -- `waydroid container restart` alone does NOT re-mount.

USAGE
-----
    python3 patch-libndk-map32.py <libndk_translation.so>

The input file is modified in place. Refuses to patch if the bytes at the
target offset do not match this exact revision.
"""
import sys

BUILD_ID = "125abe4474cee6c228658bad2f793726"
SIZE = 8743696

# (file_offset, expected_bytes, replacement_bytes, description)
PATCHES = [
    (0x7A3DB7, "83c940", "909090",
     "or $0x40,%ecx (MAP_32BIT) -> nop nop nop"),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    path = sys.argv[1]
    data = bytearray(open(path, "rb").read())

    if len(data) != SIZE:
        print(f"WARNING: size {len(data)} != known {SIZE}; continuing anyway")

    for offset, expect, replacement, desc in PATCHES:
        actual = data[offset:offset + len(expect) // 2].hex()
        if actual != expect:
            print(f"FAIL @0x{offset:x}: expected {expect}, found {actual}")
            print("Refusing to patch: the binary does not match this revision.")
            return 1
        data[offset:offset + len(replacement) // 2] = bytes.fromhex(replacement)
        print(f"OK   @0x{offset:x}: {desc}")

    open(path, "wb").write(data)
    print("patched:", path)
    print(f"BuildId expected: {BUILD_ID}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
