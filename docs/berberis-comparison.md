# berberis A16 vs A17 — binary comparison (extracted from system.img)

| property | Android 16 (lineage-23.2) | Android 17 (lineage-24.0) |
|---|---|---|
| libndk_translation.so size | 5,403,704 | 8,743,696 |
| libndk_translation.so md5 | 1f3d8b1cb957dfe86753f7771c507561 | 2bbd2f7eb1b9db5b638c634eb3c21420 |
| Build ID | 2810e5b44895c4ea0b1ad6882ea73b73 | 125abe4474cee6c228658bad2f793726 |
| ro.berberis.version | 16.0.0 | 16.0.0 |
| separate libberberis_exec_region.so | YES (550,752 B) | YES (554,840 B) |
| host_code.h CHECK | present (line 34) | present (line 35) |
| code_pool.h CHECK | present (line 66) | present (line 68) |
| mmap_posix.cc CHECK | 115/127/133/138 | 116/128/134/139 |
| MmapImplOrDie + MAP_32BIT (or $0x40) | PRESENT | PRESENT |
| stock ro.berberis.flags | accurate-sigsegv | accurate-sigsegv,disable-heavy-opts |
| stock ro.berberis.mode | (default two-gear) | (default two-gear) |

## Conclusion
Both are berberis 16.0.0 and BOTH contain the identical architectural constraint:
  - `using HostCodeAddr = uint32_t` (host_code.h CHECK)
  - `MmapBerberis32Bit` (MAP_32BIT, `or $0x40,%ecx` before mmap@plt)
  - CodePool monotonic growth (code_pool.h CHECK + "Code pool %p: new size %zu")

=> Switching to Android 16 does NOT remove the root cause. The low-2GB
   window limit still applies and the game can still abort on pool exhaustion.

## Why try it anyway
A16 main lib is 38% smaller and assembled differently; flag table is smaller
(only accurate-sigsegv, disable-intrinsic-inlining, interpret-only,
print-code-pool-size, two-gear). Different code => different translation
volume profile. It may consume the pool slower (or faster). Must be measured.

## Flag table difference (IMPORTANT)
A16 does NOT recognise these flags that the current config sets:
  disable-heavy-opts, disable-adjacent-regions-translation,
  disable-link-jumps-between-regions, all-jumps-exit-gen-code
Setting unknown flags is harmless but useless on A16 -> the flags block
must be trimmed to A16's known set.
