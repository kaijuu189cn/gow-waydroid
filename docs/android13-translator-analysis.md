# Android 13 translator analysis — the crash root cause is ABSENT

## Executive summary

Android 13's `libndk_translation.so` is the **pre-berberis** translator
(`vendor/unbundled_google/libs/ndk_translation/`). It does **NOT** contain the
architecture that crashes Android 16 and 17:

| marker | Android 13 (64-bit) | Android 16 | Android 17 |
|---|---|---|---|
| source tree | `ndk_translation/` | `binary_translation/` (berberis) | `binary_translation/` (berberis) |
| `IsInRange<HostCodeAddr>` CHECK | **0 occurrences** | present (host_code.h:34) | present (host_code.h:35) |
| `or $0x40` (MAP_32BIT) before mmap | **0 occurrences** | present | present |
| `mmap_posix.cc` CHECK lines | 18, 24, 29 | 115, 127, 133, 138 | 116, 128, 134, 139 |
| "Code pool %p: new size" growth log | **absent** | absent | present |
| libndk_translation.so size | 2,500,792 (64-bit) | 5,403,704 | 8,743,696 |
| BuildId (64-bit lib) | 619f1b989579361ca8a7a25027432444 | 2810e5b4… | 125abe44… |

The Android 17 crash signature is:

    mmap_posix.cc:128: CHECK failed: 0xffffffffffffffff != 0xffffffffffffffff
      <- MmapImplOrDie -> ExecRegionAnonymousFactory::Create
         -> CodePool::Add -> TryLiteTranslateAndInstallRegion

Android 13's `mmap_posix.cc` only goes up to line 29 and has no
HostCodeAddr range check at all, so this failure mode does not exist there.

## Proof: MmapImpl passes flags straight through

Android 13 (x86-64), symbol `_ZN15ndk_translation8MmapImplE`:

    222b40: push %rax
    222b41: mov 0x10(%rsp),%rdi      ; addr
    222b46: mov 0x18(%rsp),%rsi      ; length
    222b4b: mov 0x20(%rsp),%edx      ; prot
    222b4f: mov 0x24(%rsp),%ecx      ; flags   <-- NOT modified
    222b53: mov 0x28(%rsp),%r8d      ; fd
    222b58: mov 0x30(%rsp),%r9       ; offset
    222b5d: call mmap@plt

Android 16/17 by contrast do `or $0x40,%ecx` (MAP_32BIT) immediately before
`call mmap@plt`, forcing every translation region into the low 2 GB.

## arm64 guest support IS present (64-bit overlay)

An earlier reading of only `backup/overlay-android13-libndk/` (all 32-bit
i386 libs) wrongly suggested arm64 games could not run. The complete overlay is
in `overlay-remaining.tar`, which contains the 64-bit pieces:

    ./system/lib64/libndk_translation.so.android13      (ELF 64-bit x86-64, 2.5 MB)
    ./system/bin/arm64/app_process64
    ./system/bin/arm64/linker64
    ./system/bin/ndk_translation_program_runner_binfmt_misc_arm64
    ./system/etc/binfmt_misc/{arm64_dyn,arm64_exe,arm_dyn,arm_exe}

and the binary contains `light_translator_arm64`, `arm64/decoder.h`,
`arm64/semantics_player.h`. So arm64-v8a games (HoK is arm64-only —
`lib/arm64/`, ELF 64-bit ARM aarch64) CAN run.

## The applied patch

`libndk_translation.so.orig` -> `.android13` differs by exactly **7 bytes**:

    file offset 0xcd284 : 75 14            -> 90 90     (NOP out a jne)
    file offset 0xcd2c0 : e8 eb 8e 17 00   -> 90 90 90 90 90  (NOP out a call)

Same 7-byte patch applied to both the 32-bit and 64-bit copies. This is a
targeted bypass of two checks (the first guards a stack-cookie comparison
path, the second a call), i.e. a compatibility shim for running on this host.

## Image identity (verified by md5)

    system.img.android13.patched.1789256952.bak = 33da303f05c7f42daf639cb0277c7e58
      == lineage-20.0-20260403-VANILLA-waydroid_x86_64-system.zip   (PHONE)
    vendor.img.android13.patched.1789256953.bak = 5a1d553f8ce8eb467e5470311573319d
      == lineage-20.0-20260403-MAINLINE-waydroid_x86_64-vendor.zip (PHONE)

    system.img.android13-atv.bak = 5ede9bece6240cb7cba62f297958cdcf
      == lineage_waydroid_tv_x86_64  ("TV form factor")  <-- NOT wanted

The "patched" in the filename is misleading: these are the stock phone images.
The `atv` files are the Android TV variant.

    Android 13 phone fingerprint:
      waydroid/lineage_waydroid_x86_64/waydroid_x86_64:13/TQ3A.230901.001/aleasto04031453:userdebug/test-keys
    Android 13 TV fingerprint:
      waydroid/lineage_waydroid_tv_x86_64/waydroid_tv_x86_64:13/TQ3A.230901.001/supechicken01052113:userdebug/dev-keys

## Why this is worth trying

Android 13 replaces the whole translator with an older, fundamentally different
design that has no low-2GB code pool constraint. If HoK's crash is caused by
that constraint (as all evidence on A16/A17 indicates), it should not occur on
Android 13.

Caveats to measure, not assume:
  * A13 is an older Android; the games' minSdk and any ART/APEX requirements
    may reject it (HoK/Genshin target modern SDK levels).
  * The translator is older and slower; frame rate will likely drop.
  * `ro.berberis.*` props do not exist here, so the flag/mode tuning in
    `20-waydroid-setup.sh` is irrelevant on A13 and must be skipped.
  * The 7-byte patch is required for the library to load at all.

## Files

    system.img.android13.patched.1789256952.bak   1,810,759,680 B  ext4 (NOT erofs)
    vendor.img.android13.patched.1789256953.bak     561,487,872 B  ext4
    backup/overlay-android13-libndk/                32-bit libs + patched 32-bit lib
    backup/overlay-android13-libndk/overlay-remaining.tar   full overlay incl. 64-bit
