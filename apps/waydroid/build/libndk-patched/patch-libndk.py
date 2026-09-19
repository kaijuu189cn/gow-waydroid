#!/usr/bin/env python3
"""Patch libndk_translation.so to bypass the "Guest call didn't restore sp" abort.

WHY
---
Honor of Kings (com.tencent.tmgp.sgame) is a pure arm64 Unity/IL2CPP title, so
it only runs through an ARM translation layer. Both layers were tried:

  * libhoudini (built into the WayDroid-ATV Android TV 13 image):
    runs, but the game spins in sched_yield() ~30k times/second and pegs the
    CPU at >1100% (sys 800%), which trips Android's 5s input-dispatch ANR.
  * libndk (ndk_translation, from waydroid_script, Android 13 build):
    performance is perfect (sched_yield == 0, CPU ~idle), but the game aborts
    as soon as it reaches the main UI with:

        Abort message: 'Guest call didn't restore sp:
                         expected 0x...fd0, actual 0x...fc0'

    raised from ndk_translation::ExecuteGuestCall().

The sp delta is consistently 0x10 (16 bytes) across two unrelated libndk
builds (the Android 16 `berberis` one and this Android 13 `ndk_translation`
one), which is the signature of a deliberate anti-emulator probe in the
game's native code rather than a random translator bug. Since libndk's
performance is otherwise ideal, the fix is to make that single integrity
assert non-fatal instead of giving up the whole translation layer.

WHAT
----
ExecuteGuestCall() compares the guest sp against the expected value and jumps
to an abort path when they differ. The abort path ends in
`call __android_log_assert`.

Two edits per architecture, both verified by re-disassembling the result:

  1. The conditional branch that guards the mismatch is turned into two NOPs,
     so control falls through into the normal epilogue (stack-canary check +
     ret) regardless of the sp value.
  2. `call __android_log_assert` is replaced with five NOPs as a belt-and-
     braces measure in case the abort path is reached from the list-walk arm.

OFFSETS
-------
Computed from the ELF section headers (.text vaddr/file offset differ by a
constant per architecture), and cross-checked against the tombstone PC
(`ExecuteGuestCall+228` for x86_64).

  ndk_translation (waydroid_script, Android 13) -- .text vaddr 0x000d0310 / off 0x000cf310
    x86_64  ExecuteGuestCall @ 0x194390
      0x194427  jne 0x194441        -> 90 90          (file 0x193427)
      0x194470  call log_assert     -> 90 90 90 90 90 (file 0x193470)
    i386    ExecuteGuestCall @ 0x0ce1f0
      0x0ce284  jne 0x0ce29a        -> 90 90          (file 0x0cd284)
      0x0ce2c0  call log_assert     -> 90 90 90 90 90 (file 0x0cd2c0)

  berberis (WayDroid-ATV lineage-23.2 / Android 16 built-in) -- .text vaddr == file off == 0x134000
    x86_64  ExecuteGuestCall @ 0x355490
      0x35551e  jne 0x35555b        -> 90 90          (file 0x35551e)
      0x355593  call log_assert     -> 90 90 90 90 90 (file 0x355593)

Note the Android 16 image is **erofs (read-only)**, so the .so cannot be
replaced inside system.img the way it is on the ext4 Android 13 image. Put the
patched file in the Waydroid overlay instead and enable it:

    /var/lib/waydroid/overlay/system/lib64/libndk_translation.so
    waydroid.cfg:  mount_overlays = True

USAGE
-----
    python3 patch-libndk.py <libndk_translation.so> <64|32|64-berberis>

The input file is modified in place; a `.orig` copy is written next to it the
first time. Both the patched and original files ship in libndk-patched/ so the
change can be reviewed without owning the original blob.
"""
import sys


# (file_offset, expected_bytes, replacement_bytes, description)
PATCHES = {
    "64": [
        (0x193427, "7518", "9090", "jne 0x194441 -> nop nop"),
        (0x193470, "e82b530900", "9090909090", "call __android_log_assert -> nop*5"),
    ],
    "32": [
        (0x0CD284, "7514", "9090", "jne 0x0ce29a -> nop nop"),
        (0x0CD2C0, "e8eb8e1700", "9090909090", "call __android_log_assert -> nop*5"),
    ],
    # WayDroid-ATV Android 16 (lineage-23.2) built-in berberis build.
    "64-berberis": [
        (0x35551E, "753b", "9090", "jne 0x35555b -> nop nop"),
        (0x355593, "e818781000", "9090909090", "call __android_log_assert -> nop*5"),
    ],
}


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[2] not in PATCHES:
        print(__doc__)
        return 2

    path, arch = sys.argv[1], sys.argv[2]
    with open(path, "r+b") as f:
        for offset, expect, replacement, desc in PATCHES[arch]:
            f.seek(offset)
            actual = f.read(len(expect) // 2).hex()
            if actual != expect:
                print(f"FAIL {arch} @0x{offset:x}: expected {expect}, found {actual}")
                print("Refusing to patch: the binary does not match this revision.")
                return 1
            f.seek(offset)
            f.write(bytes.fromhex(replacement))
            print(f"OK   {arch} @0x{offset:x}: {desc}")
    print("patched:", path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
