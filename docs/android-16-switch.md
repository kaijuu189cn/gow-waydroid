# Switch to Android 16 — completed 2026-09-15

> **Folder scope note (renamed 2026-09-20).** This directory began as the
> Android 16 switch workspace, which is why it used to be called
> `android16-switch`. That switch was then abandoned — Android 16 and 17 share
> the *berberis* translator and therefore the same bug — and the project moved
> to **Android 13** on 2026-09-16 (see `android13-switch.md`). All later work
> lived here too: the Honor of Kings crash rounds (`waydroid-hok-*.md`), the
> audio-isolation fix (`waydroid-audio-isolation-fix.md`), and the consolidated
> change list (`CHANGES.md`). The folder is now `waydroid-work`; this file stays
> as the historical record of the Android 16 attempt.
>
> What is actually installed is Android 13 —
> `system.img:/system/build.prop` → `ro.build.version.release=13`,
> `ro.build.version.sdk=33`.


## What was changed

| Item | Before (Android 17) | After (Android 16) |
|---|---|---|
| system.img | lineage-24.0 GAPPS, 1,910,972,416 B | lineage-23.2 VANILLA, 1,417,170,944 B |
| system.img md5 | 9bbe3230179076adbe7c4d3d7f9d0854 | 67eea184706ce01ed99dd96735dddbbb |
| vendor.img | lineage-24.0, 733,814,784 B | lineage-23.2, 721,117,184 B |
| vendor.img md5 | 135042e1fb65ba026cc676da9ffceec3 | 2b864dcc9eb0ce3d7ea1ede44ba53431 |
| ro.build.version.release | 17 | 16 |
| ro.build.version.sdk | 37 | 36 |
| libndk_translation.so | 8,743,696 B | 5,403,704 B |
| berberis BuildId | 125abe4474cee6c228658bad2f793726 | 2810e5b44895c4ea0b1ad6882ea73b73 |
| ro.berberis.flags (vendor stock) | accurate-sigsegv,disable-heavy-opts | accurate-sigsegv |

## Flag-set incompatibility (this was a real bug to fix)

The flag-name table is compiled into the binary, so a flag the image does not
recognise is **silently ignored**. The old default set four flags that Android 16
does not know:

    disable-heavy-opts                 <- NOT in A16
    disable-adjacent-regions-translation  <- NOT in A16
    disable-link-jumps-between-regions    <- NOT in A16
    all-jumps-exit-gen-code               <- NOT in A16

Android 16's complete flag table (extracted from system.img):

    accurate-sigsegv, disable-intrinsic-inlining, interpret-only,
    print-code-pool-size, two-gear

`20-waydroid-setup.sh` now selects the set by image:

    WAYDROID_BERBERIS_IMAGE=a16 (default) -> accurate-sigsegv,disable-intrinsic-inlining
    WAYDROID_BERBERIS_IMAGE=a17           -> the old 5-flag set

`WAYDROID_BERBERIS_FLAGS=...` still overrides both; `=stock` disables.

## Device identity restored (was lost)

`waydroid_base.prop` had been regenerated without the identity spoof. The
user explicitly required this ("还原waydroid的伪装配置"), and the A17 backup
manifest warns it is mandatory for Tencent/miHoYo titles:

    你的设备内部出现了问题。请联系你的设备制造了解详情

Restored the full 28-key Samsung Galaxy S24 Ultra (SM-S9280 / e3q) spoof from
`waydroid_base.prop.spoofed`, then corrected for Android 16:

    :17/AP3A...  ->  :16/AP3A...     (in all 7 fingerprint fields)
    e3qxxx-user 17  ->  e3qxxx-user 16   (ro.build.description)
    gralloc.gbm.device=/dev/dri/renderD129 -> /dev/dri/card2   (§4g card-node fix)

Previous file kept at `waydroid_base.prop.pre-a16`.

## Host setting that would have killed the game in ~10 seconds

`vm.overcommit_memory` was **0** on the host. Per the earlier analysis this makes
berberis' PROT_EXEC JIT reservations fail and the game aborts on
`mmap_posix.cc:128` within ~10s. Set to **1** and persisted to
`/etc/sysctl.d/99-waydroid-overcommit.conf`. Verified = 1.

## Userdata: 57 GB of game data preserved

80 GB userdata was built under Android 17. A 17->16 downgrade carries
version-locked state, so:

  * Full reflink backup taken: `/data/waydroid/userdata.a17-preserved`
    (instant, shares extents, cost 0 additional disk)
  * Cleared only the incompatible caches, keeping all games/assets:
      - `dalvik-cache/`  (held A17 ART output, e.g. `...CP2A.260605.016...`)
      - `apex/{active,decompressed,hashtree,sessions,backup,ota_reserved}`
  * Preserved untouched: `app/` (13 GB), `media/` (44 GB), `system/`, settings

## Rollback

    # config + images
    /data/waydroid/android17-config-20260913-094423/restore-android17.sh --images

    # userdata (only if the A16 boot damaged it)
    rm -rf /data/waydroid/userdata
    cp -a --reflink=auto /data/waydroid/userdata.a17-preserved /data/waydroid/userdata

    # image flag set back to A17
    docker build ... and set WAYDROID_BERBERIS_IMAGE=a17

## EXPECTATION — read this

The switch does **NOT** fix the crash root cause. Both images contain the
identical architecture (verified in `berberis-comparison.md`):

  * `host_code.h` CHECK `IsInRange<HostCodeAddr>` — HostCodeAddr is uint32_t
  * `MmapImplOrDie` with MAP_32BIT (`or $0x40,%ecx` before `mmap@plt`)
  * monotonic CodePool (`code_pool.h` CHECK, "Code pool %p: new size %zu")

So the low-2GB window still caps the code pool and the game can still abort on
exhaustion. Android 16 is worth testing because its translator is a 38%-smaller,
differently-built binary whose per-run translation volume may differ. That is a
measurable hypothesis, not a fix.

## Next: verify on Moonlight connect

Wolf recreates the container from `gow-waydroid:latest` on the next connect.
After connecting, confirm:

    waydroid shell -- getprop ro.build.version.release   # expect 16
    waydroid shell -- getprop ro.build.version.sdk       # expect 36
    waydroid shell -- getprop ro.berberis.mode           # expect interpret-only
    waydroid shell -- getprop ro.berberis.flags          # expect accurate-sigsegv,disable-intrinsic-inlining
    waydroid shell -- getprop ro.product.model           # expect SM-S9280
