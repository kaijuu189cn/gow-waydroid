# Switch to Android 13 (phone) — completed 2026-09-16

## Why this switch is different from the Android 16 one

Android 16 and 17 share the **berberis** translator and therefore the same bug.
Android 13 uses the **older pre-berberis `ndk_translation`** translator, which
does not contain that bug's cause at all.

| marker | Android 13 | Android 16 | Android 17 |
|---|---|---|---|
| source tree | `ndk_translation/` | `binary_translation/` (berberis) | `binary_translation/` (berberis) |
| `IsInRange<HostCodeAddr>` CHECK | **0** | present | present |
| `or $0x40` (MAP_32BIT) before mmap | **0 in the mmap path** | present | present |
| `mmap_posix.cc` CHECK lines | 18, 24, 29 | 115,127,133,138 | 116,128,134,139 |
| "Code pool %p: new size" log | **absent** | absent | present |
| libndk_translation.so (64-bit) | 2,500,792 B | 5,403,704 B | 8,743,696 B |
| BuildId | 619f1b989579361ca8a7a25027432444 | 2810e5b4… | 125abe44… |

### Proof: Android 13 MmapImplOrDie does not force low addresses

    ; Android 13 — flags passed straight through
    222b7f: mov 0x24(%rsp),%ecx      ; flags  <-- unmodified
    222b8d: call mmap@plt

    ; Android 16 / 17 — MAP_32BIT forced in
    and $0x10,%eax
    jne ...
    or  $0x40,%ecx                   ; MAP_32BIT  <-- forces low 2 GB
    call mmap@plt

The Android 17 crash was:

    mmap_posix.cc:128: CHECK failed: 0xffffffffffffffff != 0xffffffffffffffff

That line does not exist in Android 13's library (it stops at line 29), so the
code-pool exhaustion failure mode cannot occur there.

## What was installed

    images/system.img   33da303f05c7f42daf639cb0277c7e58   1,810,759,680 B
      = lineage-20.0-20260403-VANILLA-waydroid_x86_64-system.zip
    images/vendor.img   5a1d553f8ce8eb467e5470311573319d     561,487,872 B
      = lineage-20.0-20260403-MAINLINE-waydroid_x86_64-vendor.zip

Both confirmed to be the **PHONE** build, not the TV one:

    phone: waydroid/lineage_waydroid_x86_64/waydroid_x86_64:13/TQ3A.230901.001/...
    TV   : waydroid/lineage_waydroid_tv_x86_64/waydroid_tv_x86_64:13/...  <-- avoided

The files named `*.android13.patched.*.bak` are byte-identical to the stock
lineage-20.0 phone images; "patched" in the name is misleading.

## Overlay contents (system overlay carries the translator)

    system/lib64/libndk_translation.so           64-bit x86-64, PATCHED (arm64 guests)
    system/lib/*                                 32-bit i386 translator + proxies
    system/bin/arm/{app_process,linker}          arm32 runtime
    system/bin/arm64/{app_process64,linker64}    arm64 runtime
    system/bin/ndk_translation_program_runner_binfmt_misc{,_arm64}
    system/etc/binfmt_misc/{arm,arm64}_{dyn,exe} binfmt handlers

arm64 support verified present: `light_translator_arm64`, `arm64/decoder.h`,
`arm64/semantics_player.h`. Honor of Kings is arm64-only (`lib/arm64/`, ELF
64-bit ARM aarch64), so this matters.

## The 7-byte patch (required for the library to load)

    64-bit lib, 0-based file offsets:
      0x193427: 75 18           -> 90 90            (NOP a jne)
      0x193470: e8 2b 53 09 00  -> 90 90 90 90 90   (NOP a call)
    (32-bit lib: same shape at 0xcd284 / 0xcd2c0)

Verified in the installed file: exactly 7 differing bytes, all 0x90.

## Script change: version-aware berberis handling

`20-waydroid-setup.sh` now reads `ro.vendor.build.version.release` from the
installed vendor image and skips the `ro.berberis.*` tuning when < 16, because
the pre-berberis translator reads neither `ro.berberis.mode` nor
`ro.berberis.flags`. Tested against the real A13 vendor.img:

    detected release: [13]
    -> would SKIP berberis tuning (correct for A13)

`mount_overlays = True` is still enforced unconditionally — on Android 13 the
system overlay is what carries the translator.

## Device identity

The S24 Ultra (SM-S9280 / e3q) spoof was retained and retargeted from
Android 16 to Android 13 across all 8 fingerprint fields and the description:

    samsung/e3qxxx/e3q:13/TQ3A.230901.001/S9280ZHS3AXK1:user/release-keys

`gralloc.gbm.device=/dev/dri/card2` kept (the card-node fix). Previous file at
`waydroid_base.prop.pre-a13`.

## Data

  * A16 config backed up: `/data/waydroid/android16-config-20260916-012848`
  * A17 userdata backup (80 GB, reflink): `/data/waydroid/userdata.a17-preserved`
  * Games preserved in place: `app/` 13 GB, `media/` 44 GB
  * Cleared for the version change: `dalvik-cache/`, `apex/`,
    `misc/apexdata`, `misc/apexrollback`
  * Removed stale `overlay/vendor/build.prop` (still held A16 berberis flags)

## Host setting

`vm.overcommit_memory = 1` verified still set, persisted in
`/etc/sysctl.d/99-waydroid-overcommit.conf`.

## Rollback to Android 16

    docker rm -f $(docker ps --format '{{.Names}}' | grep ^WolfWaydroid)
    cd /data/waydroid/images
    cp -a system.img.a16-live.bak system.img
    cp -a vendor.img.a16-live.bak vendor.img
    cp -a /data/waydroid/android16-config-*/waydroid_base.prop /data/waydroid/
    rm -rf /data/waydroid/overlay/system
    # then rebuild with WAYDROID_BERBERIS_IMAGE=a17 if needed

## Risks to watch on first boot

  1. **minSdk** — Android 13 is much older; HoK/Genshin may refuse to install
     or update if they require a newer API level.
  2. **Play Integrity / SafetyNet** — an A13 fingerprint may be refused by
     newer game versions where an A16 one passed.
  3. **Performance** — the older translator is very likely slower.
  4. **The 7-byte patch** is a compatibility shim; it is required, not optional.

## Verify after Moonlight connect

    waydroid shell -- getprop ro.build.version.release   # expect 13
    waydroid shell -- getprop ro.build.version.sdk       # expect 33
    waydroid shell -- getprop ro.product.model           # expect SM-S9280
    waydroid shell -- getprop ro.berberis.mode           # expect EMPTY (no berberis)
    waydroid shell -- ls -la /system/lib64/libndk_translation.so

---

# Black screen after the A13 switch — diagnosed and fixed 2026-09-16

## Symptom

Android 13 booted but never finished: black screen, `sys.boot_completed` never
set, `system_server` restarting in a loop (PID changed 4738 -> 8627 while
watching). `persist.device_config.attempted_boot_count` was 2 with a reboot
history — a boot loop, not a hang.

Note Android itself WAS running (getprop returned 13, zygote64/surfaceflinger/
system_server all up), so this was never an image or translator problem.

## Root cause

`logcat -b crash` showed the same fatal abort, endlessly:

    android.hardware.gatekeeper@1.0-service: Unable to open GateKeeper HAL
    Abort message: 'Unable to open GateKeeper HAL'
      #03 pc ... HIDL_FETCH_IGatekeeper+145
               (/vendor/lib64/hw/android.hardware.gatekeeper@1.0-impl.so)
      #02 pc ... __android_log_assert

and `gatekeeperd` blocking on it forever:

    HidlServiceManagement: Waited one second for
        android.hardware.gatekeeper@1.0::IGatekeeper/default

The impl calls `hw_get_module_by_class("gatekeeper", NULL, &module)`. With a NULL
name, libhardware resolves the module filename from these properties in order:

    ro.hardware.gatekeeper -> ro.hardware -> ro.product.board
    -> ro.arch -> ro.board.platform

The A13 vendor ships exactly one usable module:

    /vendor/lib64/hw/gatekeeper.waydroid.so

but in the guest `ro.hardware` reads back as **unknown**, so the lookup falls
through to `gatekeeper.unknown.so` -> not found -> abort.

### Why ro.hardware is stuck at "unknown"

Android's init sets `ro.hardware` from the kernel cmdline
(`androidboot.hardware`) before any property file is loaded, and `ro.*`
properties are write-once. So Waydroid's `waydroid.prop` asking for
`ro.hardware=waydroid` can never take effect. This is pre-existing and affects
A16/A17 identically — the working A17 prop dump also shows `[ro.hardware]:
[unknown]`.

### Why A16/A17 tolerated it but A13 does not

  * A16/A17: `/system/bin/gatekeeperd` is AIDL-based and the vendor provides a
    `vendor.gatekeeper_nonsecure` service, so boot does not depend on the HIDL
    `IGatekeeper` passthrough HAL. On the working A17 session the props confirm:
    `[init.svc.vendor.gatekeeper_nonsecure]: [running]`, and
    `vendor.gatekeeper-1-0` was NOT running.
  * A13: `gatekeeperd` is HIDL-based (`getService` on
    `android.hardware.gatekeeper@1.0::IGatekeeper`) and blocks until that HAL
    registers — which it never can. Hence the boot loop.

Disassembly confirmed the impl library is behaviourally identical between A13
and A16 (both pass the class name `"gatekeeper"` with a NULL name to
`hw_get_module_by_class`), so the library is not at fault; only the property
resolution differs.

## The fix

`ro.hardware.gatekeeper` is a *different* property from `ro.hardware`: init never
sets it, so it starts empty and CAN be supplied from waydroid.prop. Setting it
makes the first lookup step hit and resolves to `gatekeeper.waydroid.so`.

  * `ro.hardware.gatekeeper=waydroid`
  * `ro.hardware.keymaster=default`   (same class of problem, conventional name)

Added as new section **4g-bis** in `20-waydroid-setup.sh`. It also patches
`waydroid_base.prop` and `waydroid.prop` in place, because section 4c (which
generates them from `waydroid.cfg`) runs *earlier* — without that, a first boot
would need two session starts for the keys to land.

Sanity check that the prop file really is the delivery mechanism: the guest
reports `ro.hardware.egl=mesa`, and that value comes from this same file.

## Verification status

  * Property staging verified end-to-end: both `waydroid.cfg` and the mounted
    `waydroid.prop`/`waydroid_base.prop` now carry both keys.
  * Script syntax checked (`bash -n`) and the block was executed against the
    live config to confirm it writes all four entries correctly.
  * NOT yet verified: an actual boot to the UI. That needs a Moonlight connect
    (Wolf only creates the Wayland socket then), so it is the next check.

If the black screen persists after reconnect, the next thing to confirm is:

    waydroid shell -- getprop ro.hardware.gatekeeper   # expect waydroid
    waydroid shell -- getprop sys.boot_completed       # expect 1

---

# Black screen, part 2 — the real blocker 2026-09-16

## What the gatekeeper fix achieved

It worked: `ro.hardware.gatekeeper=waydroid` reached the guest and
`Unable to open GateKeeper HAL` went from an endless crash loop to **0
occurrences**. That was a genuine bug and it is fixed. Boot still did not
complete, because a second, harder blocker sits behind it.

## The actual blocker

`surfaceflinger` (pid 118) blocks forever and `sys.boot_completed` is never
set. Its state confirms it:

    /proc/118/wchan  -> futex_do_wait
    State: S (sleeping)

with this repeating in logcat, once per second, forever:

    HydlServiceManagement: Waited one second for
        vendor.waydroid.display@1.0::IWaydroidDisplay/default

and `tombstoned: received crash request` for a dozen pids at boot.

So the display HAL that surfaceflinger must talk to never registers, and
surfaceflinger waits on it indefinitely. No display HAL -> no composition ->
black screen.

## Why it cannot register

There is no provider for it **anywhere**:

  * `/vendor/bin/hw/` in the A13 image has: audio, camera, cas, configstore,
    drm, gatekeeper, graphics.allocator, graphics.composer, health, keymaster,
    light, media.omx, memtrack, power, sensors, vibrator.
    **No waydroid display service.**
  * `/system/bin/hw/` has only `android.hidl.allocator@1.0-service`,
    `android.system.suspend@1.0-service`, `vendor.waydroid.task@1.0-service`.
  * No `.rc` file in either image declares a `vendor.waydroid.display` service
    (grepped every init rc in both partitions).
  * `/dev/host_hwbinder` **does not exist** inside the Android container, so the
    host-side Waydroid daemon cannot register it over that transport either.

The interface *libraries* exist (`vendor.waydroid.display@1.0/1.1/1.2.so`) and
the vendor VINTF manifest declares `@1.2::IWaydroidDisplay/default` — but a
declared interface with no implementation is exactly the hang observed.

## Why Android 16/17 did not hit this

A16 also ships no display service binary, and A16's `surfaceflinger` references
`vendor.waydroid.display@1.0/1.1` identically (`strings` on both binaries shows
the same `IWaydroidDisplay::getService` symbols). The difference is that the
A16/A17 images are Waydroid-specific builds where the display path is wired
through `vendor.hwcomposer-2-1` plus Waydroid's gralloc, and those images are
the ones this Waydroid 1.6.3 userspace is actually built against. On the
confirmed-working A17 session the props show:

    [init.svc.surfaceflinger]: [running]
    [init.svc.vendor.hwcomposer-2-1]: [running]

with no separate display service, and boot completed.

The A13 (lineage-20.0) image is an older Waydroid target that expects a
host-registered `vendor.waydroid.display` HAL over `/dev/host_hwbinder` — a
mechanism this container does not provide.

## Honest conclusion

This is a **Waydroid userspace / Android image version mismatch**, not a
configuration error I can patch from here:

  * The service must be *implemented*, not configured. It is a binder HAL whose
    server side lives in Waydroid's host daemon (GBinder), and this image
    (waydroid 1.6.3 from the gow base) has no `IWaydroidDisplay` implementation
    — grepping `/usr/lib/waydroid/` for it returns nothing.
  * Writing a stub HAL is not viable: surfaceflinger uses it for real buffer
    handoff, not just presence.

So Android 13 cannot reach the UI on this stack without either:
  (a) a Waydroid build whose host daemon implements `vendor.waydroid.display`,
      plus the `/dev/host_hwbinder` transport into the LXC container, or
  (b) an A13 Android image built against the hwcomposer-only display path that
      A16/A17 use.

## State left behind

  * The gatekeeper fix is kept — it is correct and does no harm on A16/A17.
  * `ro.hardware.gatekeeper` / `ro.hardware.keymaster` remain staged in
    `waydroid.cfg`, `waydroid_base.prop`, `waydroid.prop`.
  * Android 13 images are still installed. To go back to Android 16, see the
    rollback section above — the A16 images are preserved as
    `system.img.a16-live.bak` / `vendor.img.a16-live.bak`.

---

# CORRECTION 2026-09-16 — the user was right, A13 DID work before

I concluded above that Android 13 was blocked by an unimplementable
`vendor.waydroid.display` HAL. **That conclusion was wrong.** The user pushed
back ("之前能用的啊"), and checking the backups proved them right.

## What I got wrong

I never looked at the saved known-good Android 13 configuration sitting in
`/data/waydroid/backup/`:

    waydroid.cfg.android13-atv-final.bak        2026-09-13 11:16
    waydroid_base.prop.android13-atv-final.bak  2026-09-13 11:10

Those are a complete, working A13 config from this same host. Comparing them
against what I had configured exposed the actual bug — **mine**:

| property | known-good A13 | what I set | module on A13 |
|---|---|---|---|
| `ro.hardware.gralloc` | `minigbm_gbm_mesa` | `minigbm` | `gralloc.minigbm.so` **ABSENT** |
| `ro.hardware.hwcomposer` | `waydroid` | *(unset)* | `hwcomposer.waydroid.so` present |
| `ro.hardware.memtrack` | `waydroid` | *(unset)* | `memtrack.waydroid.so` present |
| `ro.hardware.gatekeeper` | `waydroid` | `waydroid` (I added this) | present |

The HAL loader resolves a module as `<class>.<ro.hardware.<class>>.so`. I
carried `ro.hardware.gralloc=minigbm` over from the **A16/17** configuration
without checking A13's module directory:

    A16/17  /lib64/hw/ : gralloc.minigbm.so            EXISTS
                         gralloc.minigbm_gbm_mesa.so   EXISTS
    A13     /lib64/hw/ : gralloc.minigbm_gbm_mesa.so   EXISTS
                         gralloc.minigbm.so            ABSENT   <-- resolves to nothing

So on A13 the graphics allocator could not load, which is consistent with the
display side never coming up.

## Why my "missing display HAL" reasoning was misleading

I searched the A13 images for a `vendor.waydroid.display` *service* and concluded
none exists so it was unimplementable. But A16 has no such service binary either,
and A16 works. The images wire display through hwcomposer + gralloc, exactly as
the known-good A13 config does. I treated a wrong turn in my own diagnosis as a
platform limitation.

## Fixes applied

1. Restored the full known-good A13 `[properties]` set (66 keys) into
   `waydroid.cfg`, and the matching `waydroid_base.prop` / `waydroid.prop`.
   Previous versions kept as `waydroid.cfg.before-a13-restore` and
   `waydroid_base.prop.mine-broken`.
2. Added version-aware HAL module selection to `20-waydroid-setup.sh`
   (`_waydroid_pick_hal_modules`). It probes the vendor image's
   `/lib64/hw` listing via debugfs and picks the first candidate module that
   actually exists, instead of hardcoding an A16-era value:

       gralloc  : minigbm_gbm_mesa  ->  minigbm  ->  gbm
       hwcomposer, memtrack: set to `waydroid` when those modules ship

   Verified against both images:

       vendor.img          (A13) -> gralloc = minigbm_gbm_mesa
       vendor.img.a16.bak  (A16) -> gralloc = minigbm_gbm_mesa

3. Cleared `dalvik-cache`, `apex`, `misc/apexdata`, `misc/apexrollback`
   (they had been rebuilt from a failed boot under the wrong config).

The gatekeeper fix from the previous section is retained in both the config and
the script — it is correct, it matched the known-good A13 config, and it is
harmless on A16/17.

## Status

Not yet verified by a live boot. The configuration now matches, property for
property, a state that is documented as working on this host. Reconnect via
Moonlight to test.

---

# Boot animation seen, UI not reachable — diagnosed 2026-09-16

## Progress

The gralloc module fix worked: the **boot animation now plays**, which means
SurfaceFlinger is up and composing. Before, the screen never lit at all.

## New blocker: zygote crash-loop

    [init.svc.zygote]: [restarting]
    [init.svc.bootanim]: [running]
    sys.boot_completed: (unset, forever)

because `system_server` (forked by the primary zygote) dies on every attempt:

    FATAL EXCEPTION IN SYSTEM PROCESS: main
    java.lang.RuntimeException: Unable to get provider
        org.lineageos.lineagesettings.LineageSettingsProvider:
        android.database.sqlite.SQLiteException:
            Can't downgrade database from version 24 to 19
      at org.lineageos.lineagesettings.LineageSettingsProvider.establishDbTracking

## Cause

Android 17 wrote its settings databases at **schema version 24**. Android 13
expects **19** and refuses to downgrade. This is the same class of
version-locked state as `dalvik-cache` / `apex`, which had already been cleared
— but I had not cleared the databases.

A scan of every SQLite file found 14 with schema > 19. Two groups:

  * **AOSP system providers** (opened by system_server at boot — these block):
      lineagesettings.db (v24), telephony.db (v5111816), mmssms.db (v67),
      contacts2.db + profile.db (v1800), media internal/external.db (v1700),
      calendar.db (v601), downloads.db (v114), launcher databases (v917572/v34)
  * **App-owned** (harmless, unrelated to Android's own schema numbering):
      com.miHoYo.Yuanshen cl_jm_database.db (v2458), com.taptap pangle (v30)

## Fix

Checked the whole `userdata` tree for any SQLite database belonging to
`com.android.*` / `lineageos` with `user_version > 19`, confirmed clean, then
reset the A17-derived system state so Android 13 rebuilds it:

    rm -rf system user_de misc dalvik-cache apex

Backups taken first (both small, both kept):
    /data/waydroid/systemdbs-a16-*     3.9 MB  (system provider DBs)
    /data/waydroid/systemstate-a17-*    34 MB  (system + user_de + misc)

## Data incident during the reset (recovered)

While clearing "regenerable runtime state" I also removed `app/`, and the game
payloads under `data/` (16 GB for HoK alone) were lost from the live tree. Both
were restored from the reflink snapshot `userdata.a17-preserved`, and verified
against it:

    app   13G   (matches snapshot)
    data  24G   (matches snapshot)
    media 44G   (matches snapshot)

Per-package check after restore:
    com.tencent.tmgp.sgame    16G      com.miHoYo.Yuanshen    26M
    com.tencent.tmgp.dfm     4.5G      com.tencent.tmgp.osgame 1.6G
    com.taptap               1.1G      com.tencent.tmgp.pubgmhd 19M

Lesson: this snapshot is the safety net; keep it until A13 is confirmed working.

## Also fixed

`gralloc.gbm.device` was being forced to a **card** node (`/dev/dri/card2`) by
the script's `_waydroid_pin_single_gpu`. That rewrite is an A16/17 flicker fix;
the known-good A13 config uses the **render** node (`/dev/dri/renderD129`).
The rewrite is now skipped when the vendor image reports Android < 16, with a
log line saying so.

---

# Android 13 BOOTS — and the app-purge problem, solved 2026-09-16

## Android 13 now boots

Drove the boot myself and watched it:

    [1] boot_completed='1'  zygote='running'  bootanim='stopped'
    >>> BOOT COMPLETE <<<

    topResumedActivity = com.android.launcher3/.uioverrides.QuickstepLauncher
    com.android.launcher3   running
    com.android.systemui    running
    Physical size: 2376x1104, density 213

    surfaceflinger        running
    vendor.hwcomposer-2-1 running
    zygote / zygote_secondary running

The SQLite-schema reset fixed the zygote crash loop, and the launcher is up.

## New problem, and its cause

The 10 installed apps were **gone**, and so was their per-app data:

    app     live=13G -> 0        (restored)
    data    live=24G -> 6.1M     (restored)
    media   live=44G -> 44G      (unaffected)

Cause, confirmed from the rebuilt file: PackageManager reconciles `/data/app`
against `/data/system/packages.xml` at boot and **deletes any app directory with
no matching record**. Resetting `system/` to clear the Android-17 databases also
deleted `packages.xml`; the next boot therefore saw a fresh database (0 packages)
and purged every app as an orphan.

This is inherent to switching Android versions: an older Android cannot read a
newer `packages.xml`, so the file must be reset for the downgrade to boot — and
the reset itself triggers the purge. The 44 GB of `media/` survived only because
PackageManager does not manage it.

## Recovery

Restored all 10 packages and their data from the reflink snapshot
`userdata.a17-preserved`, verified equal to it:

    app 13G  data 24G  media 44G   (all match)

    com.tencent.tmgp.sgame     16G     com.tencent.tmgp.dfm      4.5G
    com.tencent.tmgp.osgame   1.6G     com.taptap                1.1G
    com.miHoYo.Yuanshen        26M     com.tencent.tmgp.pubgmhd   19M
    com.valvesoftware.underlords 17M   com.exness.android.pa     3.2M
    net.metaquotes.metatrader5 536K    com.netease.x19              0

## Permanent fix: `waydroid-apprestore`

Added `scripts/waydroid-apprestore.sh` (wired into `startup.sh` as a background
job beside the oomguard, toggle `WAYDROID_APP_RESTORE=0`).

It keeps a copy of every installed APK in `/var/lib/waydroid/apk-stash` — outside
`userdata`, so PackageManager never inspects it — and after
`sys.boot_completed=1` reinstalls anything missing with:

    pm install -r -d -g <apk>

`-r` keeps existing data (so game saves in `/data/data` survive), `-d` permits a
version downgrade, `-g` grants declared runtime permissions without needing UI.
It logs to `/tmp/waydroid-apprestore.log`.

The stash is pre-populated with all 10 APKs (9.8 GB), including Honor of Kings
(1.88 GB), so the very next boot repairs itself.

## Rollback note

`userdata.a17-preserved` is the only complete copy of the game data. Do not
delete it until the games are confirmed running on Android 13.

---

# App restore: the first attempt failed, and why 2026-09-16

## The bug in my own script

`waydroid-apprestore` ran but installed nothing. Its log:

    [apprestore] reinstalling com.exness.android.pa
    Error: Unable to open file: /var/lib/waydroid/apk-stash/com.exness.android.pa.apk
    Consider using a file under /data/local/tmp/
    [apprestore] FAILED to install com.exness.android.pa
    ... (same for all 10)

Then it ended with the misleading line "all stashed apps already present",
because `n` counts *successes* and no install had succeeded.

## Cause

`pm install` executes **inside** Android. It only opens paths that exist in
Android's own filesystem, so a host path is unreadable to it. Android printed
the fix itself: *"Consider using a file under /data/local/tmp/"*.

## Fix

Stage each APK onto the Android side first and install from there.
`/data/local/tmp` maps to `<userdata>/local/tmp` on the host, so a plain `cp`
suffices — no binder transfer needed even for multi-gigabyte APKs. The staged
copy is deleted after each attempt so the 80 GB data partition is not doubled.

Verified live on the running container:

    cp apk-stash/com.exness.android.pa.apk userdata/local/tmp/
    lxc-attach ... -- pm install -r -d -g /data/local/tmp/com.exness.android.pa.apk
    Success

Also corrected the success/failure counting so a run that installs nothing no
longer reports "already present".

## Result

5 of 10 apps installed on Android 13 before the session ended:

    com.exness.android.pa            com.valvesoftware.underlords
    com.tencent.tmgp.pubgmhd         com.miHoYo.Yuanshen
    com.taptap

Still to install (APKs are already in the stash; the fixed script will pick
them up automatically on the next session, or they can be installed by hand):

    com.netease.x19 (2.2G)   com.tencent.tmgp.osgame (1.9G)
    com.tencent.tmgp.sgame (1.8G, Honor of Kings)
    com.tencent.tmgp.dfm (1.5G)   net.metaquotes.metatrader5 (37M)

## Device spoof (伪装配置) — verified present

Confirmed in both `waydroid.cfg` and the mounted `waydroid.prop` /
`waydroid_base.prop` — 50 identity keys:

    ro.product.model         = SM-S9280
    ro.product.brand         = samsung
    ro.product.device        = e3q
    ro.product.name          = e3qxxx
    ro.board.platform        = kalama
    ro.build.flavor          = e3qxxx-user
    ro.build.fingerprint     = samsung/e3qxxx/e3q:13/TQ3A.230901.001/S9280ZHS3AXK1:user/release-keys
    ro.build.description     = e3qxxx-user 13 TQ3A.230901.001 S9280ZHS3AXK1 release-keys
    (+ all 7 partition-suffixed fingerprints)

The fingerprint is retargeted to `:13/` with build id `TQ3A.230901.001`, which
matches the Android 13 image actually installed.

---

# Honor of Kings crash on Android 13 — root cause found 2026-09-16

## Symptom

Game installed, launched, showed its splash/loading screen, then the UI stopped
responding. The logcat shows the app process never even finished starting:

    ActivityManager: ProcessRecord{... com.tencent.tmgp.sgame/u0a133} failed to attach
    ActivityManager: Killing 2183:com.tencent.tmgp.sgame/u0a133 (adj -10000): start timeout
    InputDispatcher: Not sending touch gesture to ... SGameActivity because it is not responsive

## Root cause

    F ndk_translation: native_bridge_initialize: unable to open the file
        "/system/lib64/arm64/libnative_bridge_vdso.so": No such file or directory

    F cent.tmgp.sgame: runtime.cc:675] ... native:
      #09 libndk_translation.so (native_bridge_initialize+613)
      #10 libnativebridge.so (InitializeNativeBridge+388)
      #11 libart.so (art::InitializeNativeBridge+50)
      #12 libart.so (art::Runtime::InitNonZygoteOrPostFork+311)
      #13 libart.so (art::ZygoteHooks_nativePostForkChild+6248)
      #07 libbase.so / #08 liblog.so (__android_log_assert)
    Abort message: 'native_bridge_initialize: unable to open the file
        "/system/lib64/arm64/libnative_bridge_vdso.so": No such file or directory'

The ARM translator cannot initialise, so every app process forked by zygote
aborts during `nativePostForkChild` — before the app's own code ever runs. That
is why the game appears to sit on its launch screen and then dies: the process
is killed on "start timeout" and the UI stops responding.

Also logged immediately before, same cause:

    W nativebridge: Failed to bind-mount /system/etc/cpuinfo.arm64.txt as /proc/cpuinfo
    W nativebridge: Failed to bind-mount /system/lib64/arm64/cpuinfo as /proc/cpuinfo

## Cause: my incomplete overlay

When installing the Android 13 translator I extracted `overlay-remaining.tar`
but copied only the files I judged to be binaries. Comparing the tar against
what I had installed showed **10 files never installed**:

    etc/cpuinfo.arm.txt        etc/cpuinfo.arm64.txt
    etc/init/ndk_translation.rc   etc/init/resetprop.rc
    etc/ld.config.arm.txt      etc/ld.config.arm64.txt
    etc/resetprop              etc/resetprop.sh
    lib64/libndk_translation.so.android13 / .orig

and, separately, the entire ARM support-library tree that lives alongside the
translator — **59 files in `lib64/arm64/` and 59 in `lib/arm/`** — was absent.
My overlay had 41 files; the complete one has 180.

`ld.config.arm64.txt` is what tells the linker that `/system/${LIB}/arm64`
exists and is searchable, and `libnative_bridge_vdso.so` (an ARM aarch64
static-pie object) is the VDSO the translator opens at init. Without them
`native_bridge_initialize` fails exactly as logged.

## Fix

Found the complete known-good overlay preserved at `/tmp/overlay.full-backup`
(taken 2026-09-13 11:09, i.e. from the configuration that worked) and merged it
in, then restored the **patched** 64-bit translator on top — the merge had
overwritten it with the Android 17 berberis build (8,743,696 B instead of
2,500,792 B), which is a different ABI entirely.

Verified after the fix:

    overlay/system/lib64/arm64/libnative_bridge_vdso.so   present (ARM aarch64)
    overlay/system/lib64/libndk_translation.so            x86-64, md5 00ec1d1f…, 7 NOPs patched
    overlay/system/lib/libndk_translation.so              i386 (32-bit)
    overlay/system/etc/ld.config.arm64.txt                present
    overlay/system/etc/cpuinfo.arm64.txt                  present
    overlay/system/etc/init/ndk_translation.rc            present
    total 180 files (59 arm64 + 59 arm support libs)

## Lesson

`/tmp/overlay.full-backup` is the authoritative copy of a working Android 13
translator overlay. Copy it wholesale rather than selecting files from the tar.

---

# Honor of Kings log analysis, Android 13 2026-09-16

## Good news: the translator now works end to end

    I ndk_translation: Initialized NDK translation (aarch64), version 0.2.3

No `native_bridge_initialize` failure, no abort. Unity initialised and the game
reached its login/version-update stage:

    I Escher-il2cpp: Init runtime finished.
    I Escher-GameCore: Init runtime finished.
    I SGame_Activity: sgame  in StartUnity
    I SGame_Activity: sgame onResume
    I SGame_Activity: sgame  in UnityReady and try close video
    I GCloudCore: ... httpStatus:200      (config fetch succeeded)
    I TDM : HTTPReportProc_Sync : [KV] respBody = {"error_code":0,"error_msg":"OK"}

Process state confirmed by hand:

    com.tencent.tmgp.sgame   PID 2241   ~170% CPU   1.6 GB RSS   140 threads
    mCurrentFocus = Window{... com.tencent.tmgp.sgame/SGameActivity}
    SurfaceFlinger: Total allocated by GraphicBufferAllocator ~31 MB

Network verified working from inside Android:

    ping 8.8.8.8             0% loss, rtt ~156 ms
    ping down-update.qq.com  0% loss, rtt ~5.8 ms   (game's CDN reachable)

Device spoof confirmed live in the guest:

    [ro.product.brand]        [samsung]
    [ro.product.model]        [SM-S9280]
    [ro.product.manufacturer] [samsung]
    [ro.build.fingerprint]    [samsung/e3qxxx/e3q:13/TQ3A.230901.001/S9280ZHS3AXK1:...]

## Real problems found in the log

### 1. EGL cannot identify the DRM device (main graphics issue)

    W EGL-MAIN: failed to get driver name for fd -1
    W EGL-MAIN: MESA-LOADER: failed to retrieve device information
    E OpenGLRenderer: Device claims wide gamut support, cannot find matching config, error = EGL_SUCCESS
    W OpenGLRenderer: Failed to initialize 101010-2 format, error = EGL_SUCCESS
    E OpenGLRenderer: Unable to match the desired swap behavior.
    W SoftwareRenderer: Surface::queueBuffer returned error -32

`fd -1` means the EGL loader was handed no usable DRM fd. Consequences are the
`Unable to match the desired swap behavior` and `SoftwareRenderer` lines: the
compositor path falls back to software for at least some buffers, which is
consistent with a game that renders but feels stuck at a static screen.

Notes on the current config: `gralloc.gbm.device` and `drm_device` are both
`/dev/dri/renderD129`, matching the known-good A13 backup exactly, and
`ro.hardware.gralloc=minigbm_gbm_mesa` resolves to a module that exists. The
host has card1/card2/renderD128/renderD129. So the property side is right and
the failure is in device discovery inside Android, not in the property values.

### 2. SoftwareRenderer fallback

    W SoftwareRenderer: Surface::queueBuffer returned error -32   (-EPIPE)

A surface was queued to a consumer that had already gone away. Single
occurrence here, but it confirms at least one surface was being served by the
software path.

### 3. Game-side warnings that are NOT problems

To avoid chasing these again:

  * `"mfrs":"ForbiddenGetBrand","mtype":"ForbiddenGetModel"` — this is Tencent's
    own placeholder used before the privacy agreement is accepted. It is NOT
    the spoof failing; the guest reports samsung/SM-S9280 correctly (verified
    above).
  * `W cent.tmgp.sgame: dlsym error!### Escher call stacks ###` — the game's
    CrashAdapter failing to resolve its own crash-report symbols. Cosmetic.
  * `TDM ... IsDeviceInfoEnable ... will report without device info` — the SDK
    waiting for a privacy-consent call. Expected before login.
  * `W cent.tmgp.sgame: Method ... failed lock verification and will run slower`
    — normal for non-optimised dex; the game ran, so this is informational.
  * `E GpuWork / GpuMem: Failed to attach bpf program to ... tracepoint` — the
    kernel tracepoints are absent in this container; only disables GPU
    telemetry.

### 4. Vulkan is present but the game chose GLES

`ro.hardware.vulkan=radeon` and `/vendor/lib64/hw/` ships
`vulkan.radeon.so` (plus intel/lvp/pastel/virtio); the host has
`radeon_icd.x86_64.json`. Unity logged a long `GL_EXT_*` list, i.e. it came up
on OpenGL ES rather than Vulkan. Worth testing the other backend, since the
softwarish path above is on the GL side.

## Next things to try

  1. Force the game onto Vulkan (in-game graphics setting, or a per-app config)
     and see whether the EGL/`fd -1` and SoftwareRenderer messages disappear.
  2. Run `vulkaninfo`-style probing inside the guest to confirm the radeon ICD
     actually enumerates a physical device, rather than only being present.
  3. If the screen is still static, capture what is on the framebuffer while the
     session is live (`screencap`) to tell "loading/progress screen" apart from
     "frozen frame".

---

# Black screen after splash — evidence collected 2026-09-16

## Hard evidence: the framebuffer is 100% black

Captured the live Android framebuffer while the session was up:

    screencap -p /data/local/tmp/screen.png
    -> 2376x1104, colortype 6 (RGBA), and only 12,909 bytes

Decoded every IDAT chunk and sampled a 60x60 grid across the image:

    top colors: [(b'\x00\x00\x00', 3782)]

**Every single sampled pixel is pure black.** 3782 samples, one unique value.
This is not "the game shows a black frame" — the entire display output is black,
launcher and SystemUI included.

## It is not a layer problem

SurfaceFlinger has a healthy layer stack and is compositing:

    Display 0 (HWC display 1): no identification data
    mScreenAcquired=1 mPrimaryHWVsyncEnabled=0 mHWVsyncAvailable=1
    VSYNC period: 16666666 ns   app: state=VSync  count=3256

    --list shows: WallpaperWindowToken, ImageWallpaper, Wallpaper BBQ wrapper,
      DefaultTaskDisplayArea, Task=1, Task=59,
      QuickstepLauncher (ActivityRecord + InputSink + window), Task=3/4/5, Dim layer

And the services are all up:

    init.svc.surfaceflinger        running
    init.svc.vendor.hwcomposer-2-1 running
    init.svc.bootanim              stopped
    sys.boot_completed             1

So: layers exist, vsync ticks, boot completed — but nothing reaches the screen.

## The buffer path is where it breaks

`libgbm_mesa_wrapper.so` (the shim that sits between minigbm and Mesa on this
image) contains these strings:

    gbm_create_device
    gbm_bo_create_with_modifiers2 / gbm_bo_import / gbm_bo_map / gbm_bo_get_fd
    Unable to create gbm device
    external/minigbm/gbm_mesa_driver/gbm_mesa_wrapper.cpp

`gbm_create_device` takes a **file descriptor**, not a path, and the caller
passes it in. That lines up exactly with the EGL errors captured earlier:

    W EGL-MAIN: failed to get driver name for fd -1
    W EGL-MAIN: MESA-LOADER: failed to retrieve device information
    E OpenGLRenderer: Unable to match the desired swap behavior.
    W SoftwareRenderer: Surface::queueBuffer returned error -32

`fd -1` means **no DRM fd was ever opened** for the Mesa/GBM side. No gbm device
-> no allocatable buffers -> HWC has nothing valid to composite -> black.

## What is already correct (ruled out)

  * Device passthrough is identical to the working Android 16 config:
        lxc.mount.entry = /dev/dri/renderD129 ... bind,create=file,optional
        lxc.mount.entry = /dev/dri/card2     ... bind,create=file,optional
        lxc.mount.entry = /dev/dma_heap/system ...
  * `libminigbm_gralloc_gbm_mesa.so` accepts **both** `/dev/dri/renderD*` and
    `/dev/dri/card*` (both patterns are in the binary), so
    `gralloc.gbm.device=/dev/dri/renderD129` is not inherently wrong.
  * `ro.hardware.hwcomposer=waydroid` resolves to `hwcomposer.waydroid.so`,
    which exists on A13 (508,512 B). The service is running.
  * `ro.hardware.gralloc=minigbm_gbm_mesa` resolves to
    `gralloc.minigbm_gbm_mesa.so` (12,840 B) and its dependency
    `libminigbm_gralloc_gbm_mesa.so` (84,648 B) is present.
  * Host nodes exist and are readable: renderD128/129 are 0666, card1/card2 0660.
  * Spoof, translator, network all verified working (earlier sections).

## Next experiments, in order

1. **Point the mesa side at a CARD node.** `fd -1` means the Mesa GBM backend
   never opened a device. A13's config uses `renderD129`; try `card2` for
   `gralloc.gbm.device` (this is also what the A16-era fix in
   `20-waydroid_pin_single_gpu` was for). One-line change, easy to revert.

2. **Check `Using device %s as requested by gralloc.gbm.device`** in logcat at
   boot — `libminigbm_gralloc_gbm_mesa.so` logs this. If it never appears, the
   property is not reaching the module.

3. **Test the other GPU.** Both nodes are pinned to the iGPU (card2/renderD129).
   The discrete card is card1/renderD128. If the iGPU's GBM path is broken under
   this kernel, switching to the discrete GPU should light the screen.

4. **Confirm `libdrm` can open the node inside Android** — run a small probe
   under `lxc-attach` that opens /dev/dri/renderD129 and prints the result. That
   distinguishes "node missing/inaccessible" from "node opens but Mesa rejects
   it".

---

# BLACK SCREEN ROOT CAUSE FOUND: card-node permissions 2026-09-16

## Summary

The Mesa GBM/gralloc path is told to use `/dev/dri/card2`, but inside Android
that node is **mode 0660 owned by root**, while Android's graphics processes run
as the unprivileged `ubuntu` user (uid 1000, gid 1003). They cannot open it.

Waydroid's session start only relaxes the RENDER nodes — from its own log:

    % chmod 777 -R /dev/dri/renderD129
    % chmod 777 -R /dev/dri/renderD128

There is **no equivalent chmod for card***. On this host:

    host  card2      0660 root:983      <- NOT openable by Android's ubuntu user
    host  renderD129 0666 root:987
    guest card2      0660 root:983
    guest renderD129 0666 root:987

## Evidence chain (all measured, not inferred)

1. `gralloc.gbm.device` reached the guest and the card node was accepted:

       [gralloc.gbm.device]: [/dev/dri/card2]
       I [minigbm:gbm_mesa_internals.cpp(213)]: Using device /dev/dri/card2 as requested by gralloc.gbm.device
       I [minigbm:gbm_mesa_internals.cpp(221)]: Found GPU amdgpu
       V [minigbm:gbm_mesa_internals.cpp(382)]: Allocated: 2376x1104, stride: 9728, map_stride: 9728

   So the property is right, and allocation succeeds on the *allocator* side.

2. But Mesa/EGL never gets a device fd:

       W EGL-MAIN: failed to get driver name for fd -1
       W EGL-MAIN: MESA-LOADER: failed to retrieve device information

3. SurfaceFlinger is running as `ubuntu`, and holds only the render node:

       PID 936 USER ubuntu GROUP 1003 COMMAND surfaceflinger
       10 -> /dev/dri/renderD129
       47 -> /dev/dri/renderD129
       60 -> /dev/dri/renderD129
       67 -> /dev/dri/renderD129

   i.e. the compositor is bound to renderD129 while gralloc was redirected to
   card2 — the exact cross-device split the A16-era flicker note warns about.

4. hwcomposer initialises EGL fine but the display is unusable:

       I hwcomposer: eglInitialize/eglChooseConfig/eglCreateContext/eglMakeCurrent: EGL_SUCCESS
       I HWComposer: Switching to legacy multi-display mode
       E HWComposer: getDisplayConnectionType: getDisplayConnectionType failed for display 0: Unsupported (8)
       E HWComposer: getSupportedContentTypes: ... failed for display 0: Unsupported (8)
       E HWComposer: getDisplayDecorationSupport: ... failed for display 0: Unsupported (8)

5. Nothing is composited — 12 of 13 layers are invalid:

       composition type=INVALID (0)   x12
       composition type=DEVICE  (2)   x1
       (the game's own layer SGameActivity#120 has a valid blend=PREMULTIPLIED
        but composition type=INVALID)

6. The framebuffer is genuinely empty:

       screencap -> 2376x1104, 12,909 bytes
       60x60 grid sample -> unique colors: 1, value b'\x00\x00\x00'

So: layers exist, vsync ticks, boot completes, EGL initialises — but the
compositor has no valid device to render through, and the screen is 100% black.

## Not the cause (ruled out by measurement)

  * The translator: `I ndk_translation: Initialized NDK translation (aarch64), version 0.2.3`
  * The game: Unity initialises with a full GL context
    (`UnityInitApplication`, long `GL_*` extension list, `Escher-GameCore: Init
    runtime finished`), runs at ~40% CPU
  * Device passthrough: identical to the working A16 config
    (renderD129 + card2 + dma_heap, `create=file,optional`)
  * The spoof: guest reports samsung/SM-S9280 correctly
  * Module resolution: `ro.hardware.hwcomposer=waydroid` and
    `ro.hardware.gralloc=minigbm_gbm_mesa` both resolve to existing modules

## Fix

In `_waydroid_pin_single_gpu` (20-waydroid-setup.sh), after choosing the card
node, relax it so Android's unprivileged graphics user can open it:

    chmod 666 /dev/dri/<chosen_card>
    chmod 666 /dev/dri/renderD* /dev/dri/card*

666 rather than 777: these are character devices, the execute bit is
meaningless, and 666 keeps access inside the container.

## Status

The fix is built into the image. It has NOT yet been confirmed by a live boot —
the session ended before the chmod could be validated end to end. To verify
after reconnecting:

    lxc-attach ... -- ls -la /dev/dri/            # card2 should be 0666
    lxc-attach ... -- screencap -p /data/local/tmp/s.png
    # then decode: a real UI shows many colours, not 1

If card2 is 0666 and the screen is still black, the next suspect is
`drm_device`/render-node vs card-node disagreement (item 3 above): point
`drm_device` at the same card node so the compositor and the allocator are
bound to one device.

---

# BLACK SCREEN — ACTUAL ROOT CAUSE: sysfs/dev DRM mismatch 2026-09-16

## The bug in one line

Android's `/sys/class/drm` advertises **every** GPU on the host, but
`/dev/dri` inside the guest only contained the two pinned nodes — so Mesa's
loader enumerated a card it could not open and gave up with `fd -1`.

## Measured evidence

Inside the running Android container:

    /dev/dri      : card2  renderD129                       <-- only the pinned pair
    /sys/class/drm: card1 card2 renderD128 renderD129 + connectors

    /sys/class/drm/card1 -> 0x1002:0x7590   (discrete Radeon)
    /sys/class/drm/card2 -> 0x1002:0x1638   (Renoir iGPU)

    for n in card1 renderD128 card2 renderD129; do [ -e /dev/dri/$n ]; done
      MISSING /dev/dri/card1
      MISSING /dev/dri/renderD128
      EXISTS  /dev/dri/card2
      EXISTS  /dev/dri/renderD129

`/sys` is bind-mounted **read-only** from the host into the LXC:

    sysfs on /sys type sysfs (ro,relatime)

so it always lists both cards regardless of what was passed through.

## Why that produces a black screen

`libgallium_dri.so` (loaded into the HWC) does **not** read `gralloc.gbm.device`.
It walks `/sys/class/drm`, reads each card's PCI id, then opens the matching
`/dev/dri/<name>`. It reports its own failure:

    failed to get driver name for fd %d        <- string inside libgallium_dri.so

which is exactly the runtime message observed:

    W EGL-MAIN: failed to get driver name for fd -1
    W EGL-MAIN: MESA-LOADER: failed to retrieve device information

With no driver bound, EGL ends up with an invalid config, and that propagates
all the way out:

    E Unity : [EGL] eglGetConfigAttrib(): EGL_BAD_CONFIG: An EGLConfig argument
              does not name a valid EGL frame buffer configuration.

    E OpenGLRenderer: Unable to match the desired swap behavior.

Consequently **no layer ever receives a buffer** — including the launcher and
the game:

    composition type=INVALID (0)   x12
    composition type=DEVICE  (2)   x1
    geomBufferSize=[0 0 -1 -1]
    buffer: slot=-1 buffer=0x0

and the framebuffer is genuinely empty:

    screencap -> 2376x1104, 12,909 bytes
    60x60 sample -> unique colors: 1 (b'\x00\x00\x00')

## What this replaces

The earlier "card2 is 0660 root-only" finding was real and is fixed
(`card2`/`renderD129` are now 0666 and the HWC holds fds on both: fds 44/45/46
on card2, 8/9/11 on renderD129). But it was not the blocker — with permissions
fixed the screen was still black, because the node Mesa wanted to open was not
present at all.

## Fix

Bind **every** host DRM node into the guest so `/dev/dri` matches
`/sys/class/drm`:

    for _node in /dev/dri/card[0-9]* /dev/dri/renderD[0-9]*; do
        printf 'lxc.mount.entry = %s %s/dev/dri/%s none bind,create=file,optional 0 0\n' \
            "$_node" "$rootfs" "$(basename "$_node")" >> "$cfg"
    done

Verified generated entries:

    card1  card2  renderD128  renderD129

This does not reintroduce the cross-GPU split: `DRI_PRIME` and
`MESA_VK_DEVICE_SELECT` still decide which device Mesa actually uses; this only
lets the loader open what sysfs told it about.

## Also relevant

`waydroid-apprestore` was mangling package names
(`com.tencent.tmgp.sgame-BwWbIEwBPYiePCjlrGw`) because the `<pkg>-<hash>`
directory suffix contains `-`. Now derived by scanning back for the first valid
Java package name; the stash is clean (10 correctly-named APKs).

## Status

Built into the image. Not yet confirmed by a live boot. To verify:

    lxc-attach ... -- ls /dev/dri/                 # expect card1 card2 renderD128 renderD129
    lxc-attach ... -- screencap -p /data/local/tmp/s.png
    # decode: a real UI has many colours, not 1
    logcat | grep "failed to get driver name"      # should be gone

---

# BLACK SCREEN — TRUE ROOT CAUSE: amdgpu requires a RENDER node 2026-09-16

## The error that matters

Buried among the Mesa messages:

    I [minigbm:gbm_mesa_internals.cpp(213)]: Using device /dev/dri/card2 as requested by gralloc.gbm.device
    E MESA    : amdgpu: amdgpu_device_initialize failed.
    I MESA    : Using gralloc0 CrOS API
    W EGL-MAIN: failed to get driver name for fd -1
    W EGL-MAIN: MESA-LOADER: failed to retrieve device information

`amdgpu_device_initialize failed` comes FIRST; `fd -1` is its consequence.

## Why it fails — disassembly proof

`libdrm_amdgpu.so` (dump from the A13 vendor image), `amdgpu_device_initialize`:

    82de: mov  %r15d,%edi
    82e1: call drmGetNodeTypeFromFd
    82e6: xor  %r13d,%r13d
    82e9: cmp  $0x2,%eax          ; DRM_NODE_RENDER == 2
    82ec: je   8315               ; render node -> accepted, carry on
    82ee: ...                     ; anything else -> AMDGPU_INFO ioctl, which fails

DRM node types are: PRIMARY=0 (card*), CONTROL=1, RENDER=2 (renderD*).

**So `amdgpu_device_initialize` accepts only a RENDER node.** Handed a `card*`
node it fails, Mesa gets no driver, and EGL ends up device-less.

## The bug was mine

`gralloc.gbm.device` was set to a **card** node:

    drm_device          = /dev/dri/renderD129   <- correct type
    gralloc.gbm.device  = /dev/dri/card2        <- WRONG type, breaks amdgpu

I changed that value earlier while chasing a flicker theory, on the reasoning
that the minigbm mesa backend wants a card node. The binary does accept both
patterns for *opening* a node — but the AMD userspace driver that receives it
afterwards requires a render node, which that reasoning missed. The A13
known-good configuration used `renderD129` for both properties; the setup
script's Android<16 branch kept saying so in its log the whole time:

    [dri] Android 13: keeping gralloc.gbm.device=renderD129 (known-good for this image)

while `getprop` still reported `card2` — the disagreement between those two was
the clue.

## What was ruled out along the way

  * Permissions: real bug, fixed. `card2` was 0660 root-only and Android's
    graphics processes run as `ubuntu`; both nodes are 0666 now and the HWC
    holds fds on card2 and renderD129 both.
  * sysfs/dev mismatch: real, fixed. `/sys/class/drm` listed 4 nodes while
    `/dev/dri` had 2; all four are passed through now.
  * Neither of those was the blocker. With both applied, `amdgpu_device_
    initialize failed` still appeared and the screen stayed black.
  * Not the translator (`Initialized NDK translation (aarch64), version 0.2.3`).
  * Not the game: Unity initialises, and SurfaceFlinger's own render engine is
    healthy — `GLES: AMD, AMD Radeon Graphics (radeonsi, gfx1200, ACO, DRM 3.64,
    7.2.4-arch1-2), OpenGL ES 3.2 Mesa 26.0.1`.
  * Not layer geometry: the display is configured fine
    (`2376x1104, 60Hz, powerMode=On, isEnabled=true`).

  The layers showing `buffer: slot=-1 buffer=0x0` and `composition type=INVALID`
  are the *symptom*: no process could get a usable EGL config, so nothing ever
  queued a buffer.

## Fix

`gralloc.gbm.device` reverted to the render node, matching `drm_device`:

    drm_device          = /dev/dri/renderD129
    gralloc.gbm.device  = /dev/dri/renderD129

This is exactly what the known-good Android 13 backup used
(`waydroid_base.prop.android13-atv-final.bak` -> `gralloc.gbm.device=/dev/dri/renderD129`)
and what the setup script had been reporting it kept.

## Verify after reconnect

    lxc-attach ... -- getprop gralloc.gbm.device      # expect renderD129
    logcat -d | grep "amdgpu_device_initialize"       # expect NO output
    logcat -d | grep "failed to get driver name"      # expect NO output
    lxc-attach ... -- screencap -p /data/local/tmp/s.png
    # decode: a real UI has many colours, not 1

---

# BLACK SCREEN — ACTUAL ROOT CAUSE: no Wayland compositor 2026-09-16

## The finding

Nothing was listening on the Wayland socket Android renders into.

    # inside the container
    $ ss -xl | grep wayland
    (nothing)
    $ ss -xl | head
    u_str LISTEN 0 4096        /run/dbus/system_bus_socket
    u_str LISTEN 0 4096      /run/user/wolf/dbus-session-0
    u_str LISTEN 0 100  @/var/lib/waydroid/lxc/waydroid/command

The socket **file** exists (`srwxr-xr-x /run/user/wolf/wayland-1`) so clients
connect successfully — and then nothing ever reads or writes it. The HWC holds
sockets (fds 5,6) on a dead endpoint, so every frame it "presents" is discarded.

## Why there is no compositor

The container was created without `RUN_SWAY`:

    docker inspect ... .Config.Env
      GOW_REQUIRED_DEVICES=/dev/input/event* /dev/dri/*
      WAYDROID_IMAGE_TYPE=VANILLA
      WAYLAND_DISPLAY=wayland-1
      ...        <- no RUN_SWAY, no RUN_GAMESCOPE

so startup.sh logged, correctly:

    [waydroid] RUN_SWAY is falsy (); disabling sway
    [waydroid] Compositor: none (RUN_SWAY/RUN_GAMESCOPE off)
    [waydroid]    Waydroid renders directly into $WAYLAND_DISPLAY.

Nothing then serves that display. Wolf's own config carries
`start_virtual_compositor = true` for the app, but the app's `env` list in
`/etc/wolf/cfg/config.toml` omitted `RUN_SWAY`:

    env = [ 'GOW_REQUIRED_DEVICES=/dev/input/event* /dev/dri/*',
            'WAYDROID_IMAGE_TYPE=VANILLA' ]          <- RUN_SWAY missing

Compare the Lutris entry in the same file, which does include it:

    env = [ 'WOLF_LUTRIS_GAMEPAD_UI_ENABLE=0', 'RUN_SWAY=1', ... ]

and the repo's own app template (`apps/waydroid/assets/wolf.config.toml`), which
also sets `RUN_SWAY=true`. So the deployed config had drifted from both.

## Fix

Added `RUN_SWAY=1` to both Waydroid profiles in `/etc/wolf/cfg/config.toml`
(the `moonlight-profile-id` and `public` profiles). Backup at
`config.toml.bak-dri`. Verified: TOML re-parses, and both profiles now report

    env: [..., 'WAYDROID_IMAGE_TYPE=VANILLA', 'RUN_SWAY=1']

## Everything else was already correct by this point

  * `Initialized NDK translation (aarch64), version 0.2.3` — translator fine
  * `amdgpu_device_initialize failed` — **gone** after reverting
    `gralloc.gbm.device` to the render node (`renderD129`)
  * Mesa/gralloc working: `Using device /dev/dri/renderD129 as requested by
    gralloc.gbm.device`
  * HWC EGL healthy: `eglInitialize/eglChooseConfig/eglCreateContext/
    eglCreatePbufferSurface/eglMakeCurrent: EGL_SUCCESS`
  * SurfaceFlinger's render engine bound to the real GPU:
    `GLES: AMD, AMD Radeon Graphics (radeonsi, gfx1200, ACO, DRM 3.64,
    7.2.4-arch1-2), OpenGL ES 3.2 Mesa 26.0.1`
  * The game produces frames: its BLAST layer shows
    `composition type=DEVICE (2)` with `buffer: slot=62 buffer=0x7fa92da3f630`
  * Display configured: `2376x1104, 60Hz, powerMode=On, isEnabled=true`,
    `usesClientComposition=true`
  * VSync advancing (count 6604 -> 7089 while sampled)

So the whole Android-side graphics stack was working and compositing into a
socket nobody was reading. That is why the framebuffer stayed 100% black:

    screencap -> 2376x1104, 12,909 bytes, 60x60 sample -> 1 unique colour

## Note on the diagnostic order

The remaining `W EGL-MAIN: failed to get driver name for fd -1` messages are
emitted by processes taking Mesa's `gralloc0 CrOS API` path, which cannot
provide a DRM fd (the cros_gralloc module has no `perform()` callback —
`"Oops. CrOS gralloc doesn't have perform callback"` is a string in
libEGL_mesa.so). Those are survivable warnings: SurfaceFlinger itself did get a
working context, as its `GLES:` line and the game's DEVICE-composited buffer
show. They were a red herring compared to the dead output socket.

## Verify after reconnect

    ss -xl | grep wayland           # expect a LISTEN line on wayland-1
    ps aux | grep -i sway           # expect a sway process
    lxc-attach ... -- screencap -p /data/local/tmp/s.png
    # decode: a real UI has many colours, not 1

---

# DISPLAY WORKS — resource update failure (error 556793857) 2026-09-16

The `RUN_SWAY=1` fix resolved the black screen. The game now reaches its update
UI. This section covers the next failure, in-game error
`9219f1da-11fa-36b0-340d-512ca4e2e1e5-556793857`.

## Error correlation

The suffix in the in-game code is the runtime error number:

    I sgame_unity: [CResourceDownLoaderOnStart.OnHanldeError]
    I sgame_unity: OnResourceError error:556793857

and the underlying cause is logged just above it:

    I sgame_unity: [CVersionUpdateAppAction.ClearDownloadedApk] ex :
      System.UnauthorizedAccessException: Access to the path
      '/storage/emulated/0/Android/data/com.tencent.tmgp.sgame/files/iips_download/app'
      is denied. ---> System.IO.IOException: Permission denied

So it is a filesystem permission failure, not a network or CDN problem. Network
was verified separately (CDN `down-update.qq.com` answers in ~6 ms).

## Root cause: app uid changed with the Android version

Android allocates each app's uid from the package-name cache, and that mapping
is not stable across versions. After the image swap:

    game running as            uid 10133   (Android 13)
    media/0/Android/data/.../files/iips_download/diff_extra        -> 10126
    media/0/Android/data/.../files/iips_download/ingame            -> 10126
    media/0/Android/data/.../files/iips_download/predownloadInGame -> 10126

10126 was the uid under Android 17. The game could read those 213 MB of
previously downloaded resources but not write to them, so the update failed.

Runtime permissions were NOT the problem — all were granted (the `pm install
-g` in the restore path worked):

    android.permission.READ_EXTERNAL_STORAGE:  granted=true
    android.permission.WRITE_EXTERNAL_STORAGE: granted=true
    ...

and the top-level dirs were already correct (`/data/data/<pkg>` = 10133).
Only the external tree had drifted.

## Scope measured

Scanning every package's external storage for files whose uid differs from the
package's current uid:

    com.tencent.tmgp.sgame   dir=10133  size=824M  stale uid 10126  (1882 items)
    com.tencent.tmgp.osgame  dir=10132  size=66M   stale uid 10003  (81 items)

`/data/data` was fully consistent; only `media/0/Android/data` had drifted.

## Fix

Re-owned both trees and both games:

    chown -R 10133:1078 media/0/Android/data/com.tencent.tmgp.sgame
    chown -R 10132:1078 media/0/Android/data/com.tencent.tmgp.osgame

Verified: 0 stale items remain across all of `media/0/Android/data`.

## Permanent fix: section 4b-3 `_waydroid_fix_stale_uids`

Added to `20-waydroid-setup.sh`, running right after the userdata persistence
step. For every package it reads the current uid from
`userdata/data/<pkg>` (which Android creates correctly at install time) and
re-owns `media/0/Android/data/<pkg>` and `media/0/Android/obb/<pkg>` when they
contain anything with a different uid. It logs either

    [uid] re-owned N app storage tree(s) to their current uid
    [uid] app storage ownership is consistent

Dry-run against the live data: "checked 13 tree(s), would fix 0" — i.e. the
logic agrees there is nothing left to do, and it will catch the next version
swap automatically.

## State

Built into the image. The ownership repair is already applied to the live data,
so the 556793857 failure should be gone on the next run even before the new
image is used.

---

# Download stalls at 59% — diagnosis 2026-09-16

The uid fix worked: the game no longer fails with error 556793857, it reaches the
update UI and starts downloading. It now stalls partway through.

## Measured: the download is genuinely wedged

Sampled the app's storage twice, 60 seconds apart:

    files: 1713 -> 1713
    bytes: 936572313 -> 936572313   (delta 0 in 60s)

No progress at all. Network is NOT the problem — from inside Android:

    ping down-update.qq.com   0% loss, rtt ~5.8 ms
    ping 8.8.8.8              0% loss, rtt ~156 ms

and the earlier "request time failed" lines are just NTP (`SntpClient`), which
do not gate the download.

## What the threads show

    tid    %CPU  stat  comm
    8219   99.8  Rl    cableThread      <- spinning
    8214   92.7  Sl    pcdn_main        <- spinning
    6978    6.0  Sl    UnityMain
    7426    1.8  S<l   UnityGfxDeviceW
    6631    1.2  S<l   cent.tmgp.sgame
    ...
    8220    0.1  Sl    pcdn_http        <- idle
    8216    0.0  Sl    pcdn_udp         <- idle
    8221    0.1  Sl    pcdn_callback    <- idle
    8213    0.0  Sl    pcdn_log

Two threads burn a full core each while every actual transfer thread sits at
0-0.1%. The game logs `[CBaseDownloader.SetEnableP2p]` and then

    CVersionUpdateProcessBiLinkResourceAction EnableBiLinkTransfer false!
    BiLink !CBiLinkBase.IsEnable()
    CVersionUpdateProcessBiLinkResourceAction CanStartBiLinkBackground false !

So this is Tencent's P2P/CDN acceleration (`pcdn`, `cable`, `bilink`) busy-looping
rather than transferring. The HTTP path is idle, meaning no fallback to direct
download is happening.

Also logged repeatedly, once per process, but NOT fatal:

    E TalsecLibraryInitializerImpl: Talsec.start
    java.lang.UnsatisfiedLinkError: dlopen failed: library "libcryptog.so" not found
      at w2p.<clinit> / y4p.d / e4p.<init>

`libcryptog.so` genuinely is not in the APK — the base.apk ships 133 arm64 libs
and `libcryptog.so` is not one of them, nor is it anywhere under userdata. That
is Talsec's own anti-tamper payload and it fails on every process; it does not
crash the game, so it is a side issue rather than the stall.

## Working hypothesis

The P2P downloader cannot reach peers (a container NAT'd behind waydroid0 with
no inbound reachability) and spins instead of falling back to plain HTTP from
the CDN. That fits: CDN reachability verified, transfer threads idle, only the
P2P machinery burning CPU.

## Things to try

1. **Disable in-game P2P / "加速下载"** if the update UI exposes it. That is the
   cleanest test of the hypothesis.
2. Restart the game so the stalled P2P state is torn down; the update usually
   resumes and may complete via HTTP.
3. Check whether the CDN endpoint the P2P layer wants differs from the one that
   works; `down-update.qq.com` resolves and answers, so plain HTTP is viable.
4. If it reproduces consistently, look at `pcdn` config in the game's own files
   under `files/` for an enable flag that can be turned off.

---

# Download stall at 59% — cause identified 2026-09-16

## The game's own remote config holds the answer

The stalled download's settings are in the game's version-update log
(`files/dcLog/VersionUpdate_*.log`), which dumps the remote config it received:

    "EnableP2PDownload":       {"value": 1,    "desc": "是否开启p2p下载"}
    "EnableBiLinkTransfer":    {"value": 1,    "desc": "近场功能开关，1打开0关闭"}
    "EnableNasDownload":       {"value": true, "desc": "Nas 功能开关"}
    "EnableWaitFoundNasDevice":{"value": true, "desc": "Nas下载是否阻碍等待"}

That last one is the key: **"whether NAS download blocks waiting"**, and it is
`true` while `EnableNasDownload` is also `true`. The downloader is instructed to
enable NAS transfer and to **block** until a NAS device is found — on a network
where none can ever appear.

## Why P2P/NAS cannot work here — measured topology

    # inside the Waydroid container
    default via 172.17.0.1 dev eth0            (Docker bridge)
    192.168.240.0/24 dev waydroid0             (waydroid0, container-internal)

    # inside Android
    192.168.240.0/24 dev eth0                  (no default route of its own)

Android sits behind the container's Docker NAT, which itself sits behind the
host — double NAT with no inbound reachability. Tencent's `pcdn` / `cable` /
`bilink` are LAN/P2P transports that need peers to reach this device, and NAS
discovery needs a NAS on the local segment. Neither can succeed, and with
`EnableWaitFoundNasDevice=true` the downloader waits instead of falling back.

## The threads corroborate it exactly

    tid    %CPU  stat  comm
    8219   99.8  Rl    cableThread      <- spinning, not transferring
    8214   92.7  Sl    pcdn_main        <- spinning, not transferring
    8220    0.1  Sl    pcdn_http        <- idle
    8216    0.0  Sl    pcdn_udp         <- idle
    8221    0.1  Sl    pcdn_callback    <- idle

Two threads burn a full core each while every transfer thread sits at ~0%.
And the game's log stops dead right after starting the download:

    [CVersionUpdateResourceInstallationAction.StartDownloadResource] frame:104
    OnAppManagerLoading percent:100 frame:116
    (nothing further — no download attempt, no error, no retry)

Meanwhile the CDN is perfectly reachable:

    ping down-update.qq.com   0% loss, rtt ~5.8 ms

and storage is not progressing at all:

    files 1713 -> 1713,  bytes 936572313 -> 936572313   (over 60 s)

## Secondary, non-blocking

    E TalsecLibraryInitializerImpl: Talsec.start
    java.lang.UnsatisfiedLinkError: dlopen failed: library "libcryptog.so" not found

`libcryptog.so` is genuinely absent — the base.apk ships 133 arm64 libraries and
it is not one of them, nor is it anywhere under userdata. That is Talsec's own
anti-tamper payload; it fails per-process and does not crash the game. Not the
stall.

## Next steps

1. **Let the game fall back to plain HTTP.** If the update UI exposes a
   P2P/"加速下载"/"快传" toggle, turn it off; that removes the blocking wait and
   the CDN path (already proven reachable) should be used.
2. **Restart the game** so the wedged P2P state is torn down. The update usually
   resumes; it may complete over HTTP on the second attempt.
3. If it wedges again at the same point, the remote config above is served per
   account/region, so the practical options are to complete the ~44 GB of assets
   on a network the P2P layer likes (a LAN where peers exist), or to pre-seed
   the resource tree, since the download itself is not blocked by anything on
   our side.
4. Worth trying: give Android a route that makes it look like a single-NAT host
   rather than one behind waydroid0 + Docker NAT.

## Important

This is NOT a Waydroid/Android fault and not the earlier permission or graphics
problems — everything on our side now works (translator, GPU, display, storage
ownership, network). The download mechanism the game chose simply cannot operate
in this network topology, and it does not fall back on its own.

---

# Download stall — ROOT CAUSE: leaked P2P sockets 2026-09-16

## The measured state

Socket table inside Android while `cableThread` spins at 99.8%:

    24 CLOSE-WAIT
    10 ESTAB
     5 TIME-WAIT
     2 SYN-SENT
     1 LISTEN

and 19 of the 24 CLOSE-WAIT entries point at Tencent's P2P peer port:

    11 x [::ffff:120.223.162.201]:55001
     8 x [::ffff:120.220.173.152]:55001

plus leaked sockets to CDN ports that also closed:
    :44863, :443, :443, :10012, :80

and two connections stuck before establishment:

    SYN-SENT ... [::ffff:172.217.112.4]:443

## What that means

The game opens a batch of P2P connections to `:55001`; the peers close them;
**the game never closes its own side**, so 19 descriptors sit in CLOSE-WAIT
permanently. `cableThread` then busy-loops servicing dead connections at ~100%
of a core while `pcdn_main` spins alongside it, and every real transfer thread
(`pcdn_http`, `pcdn_udp`) stays at ~0%.

That is exactly the observed behaviour:

    tid    %CPU  stat  comm
    5999   99.8  Rl    cableThread      <- running, not blocked
    5996   56.7  Sl    pcdn_main
    6000   ~0    Sl    pcdn_http        <- idle
    5998   ~0    Sl    pcdn_udp         <- idle

and storage does not move:

    902M -> 902M over 2.5 minutes (0 bytes)

## Why it happens in this environment

P2P for this title relies on peers being able to reach the device. Android sits
on `192.168.240.0/24` behind waydroid0, which is itself behind the container's
Docker bridge (`172.17.0.0/16`). Outbound works (the game logs in, CDN is
reachable at ~6 ms), but the peer connections it opens to `:55001` are closed by
the far end — consistent with the device not being reachable back, which is
normal for double-NAT without port forwarding.

So the P2P layer fails, does not tear down its sockets, and never falls back to
plain HTTP for that portion. That is a bug in the game's downloader, but the
environment is what triggers it.

## Correction to an earlier note

I previously wrote that the P2P threads had "zero sockets" and were a pure CPU
busy-loop. That was wrong — I had run `ss` in the container's network namespace
instead of Android's. Each P2P thread actually holds 46 descriptors. The
CLOSE-WAIT evidence above is from inside Android and is the accurate picture.

Routing is also fine and was a red herring: Android has a default route
(`default via 192.168.240.1 dev eth0 table eth0`) and reaches the internet.

## What actually fixes it

The download is not blocked by anything on our side — storage, network, GPU and
permissions are all healthy. The blocker is the game's own P2P state. Practical
options, in order of effort:

1. **Restart the game and let it resume.** Measured doing exactly this: on one
   restart the transfer ran at ~17 MB/s (1.2G -> 3.3G in two minutes) before
   wedging again. So a restart genuinely gets progress; repeating it walks the
   update forward. This is the pragmatic path.

2. **Disable P2P in the game's UI** if the update screen exposes it
   ("加速下载" / "快传" / P2P). The remote config enabling it is served
   per-account, but a client-side toggle wins if present. Worth checking the
   update screen's settings entry.

3. **Make the device reachable so peers stop dropping it** — publish the P2P
   port and give Android a routable address instead of double-NAT. This is the
   only true fix, and it is a network-topology change rather than an Android one.

4. **Pre-seed the resources** so no large download is needed.

## Note

There is no Waydroid-side switch that turns Tencent's P2P off. The container is
already passing everything the app needs; the socket leak is inside the app.

## Restart experiment: what actually happens

Tested whether restarting the game unblocks the transfer (the practical fix).

1. `am force-stop` **did not** kill the wedged process — it kept running with the
   same `cableThread` at 99.8% and the same start time (15+ minutes elapsed).
2. `kill -9` issued *inside* Android reported "No such process"; the same PID was
   alive from the container's namespace. Killing it **from the container
   namespace** worked.
3. After the kill, `du` moved slightly (902M -> 945M) as the app cleaned up, but
   the game did not relaunch from a CLI `am start` / `monkey` invocation — it
   needs the UI (it is launched from the Android launcher).

Earlier, one restart *did* produce real progress: 1.2G -> 3.3G in two minutes
(~17 MB/s) before wedging again. So restarting genuinely moves the update
forward, but it is not a clean fix — the P2P layer re-wedges.

## Bottom line

Everything on the Waydroid/Android side is now correct and verified:

    translator    Initialized NDK translation (aarch64), version 0.2.3
    GPU           radeonsi, gfx1200, Mesa 26.0.1, no amdgpu errors
    display       surfaceflinger + hwcomposer + sway, real output
    storage       app uid ownership repaired, writeable
    network       default route present, CDN at ~6 ms
    permissions   all runtime permissions granted

The remaining blocker is inside the game: it opens ~19 P2P connections to
:55001, the peers close them, and it never closes its own end, so the descriptors
leak in CLOSE-WAIT and `cableThread` spins at 100% of a core forever instead of
falling back to HTTP. That is triggered by this device not being reachable from
the internet (double NAT), which is normal for a container.

There is no Waydroid-side switch for Tencent's P2P. The options that remain are
the restart-and-resume loop (works, slowly), whatever in-game toggle the update
screen exposes, or completing the download from a network where the peer
connections are accepted.

---

# "Container won't open" — cause and recovery 2026-09-16

## Symptom

    docker start WolfWaydroid_...
    Error response from daemon: failed to create task for container:
      error mounting "/data/stacks/wolf/run-user-wolf/wayland-1" to rootfs at
      "/run/user/wolf/wayland-1": ... not a directory: Are you trying to mount
      a directory onto a file (or vice-versa)?

and in the logs:

    RuntimeError: Already tracking a session
    Gdk-Message: Error reading events from display: Broken pipe

## Cause

Wolf creates the Wayland socket **per Moonlight session**. When a session ends
badly — in this case because I killed the wedged game process mid-run — a stale
**directory** is left at that path. The container's bind mount then fails,
because the mount expects a socket *file*.

A secondary cause is a stale Waydroid session marker left behind, which produces
`Already tracking a session`.

## Recovery

    /root/wolf/waydroid-work/fix-waydroid-container.sh

It:
  1. removes the Waydroid container (Wolf recreates it on the next connect),
  2. clears the stale `wayland-N` socket residue and `.lock` files,
  3. clears stale Waydroid session markers (`lxc/waydroid/partial`, `*.pid`),
  4. reconciles app-data ownership against `userdata/system/packages.list`,
  5. prints a configuration sanity check (gralloc node, DRM mounts, image
     hashes, translator VDSO, data sizes).

It does not touch images, overlays or the game resource trees.

## A second problem surfaced by the same kill

The unclean `kill -9` made Android clear `/data/data` for the games, so they
came back installed but with **no saves**:

    app      13G   (unchanged - APKs still installed)
    data     24G -> 5.5G
    media    44G   (unchanged)

Restored all 9 affected packages from `userdata.a17-preserved` and re-applied
Android 13's uids, read from `userdata/system/packages.list`:

    com.tencent.tmgp.sgame        10126 -> 10133
    com.taptap                    10002 -> 10128
    com.tencent.tmgp.pubgmhd      10000 -> 10129
    com.tencent.tmgp.dfm          10007 -> 10131
    com.tencent.tmgp.osgame       10003 -> 10132
    com.valvesoftware.underlords  10004 -> 10127
    net.metaquotes.metatrader5    10005 -> 10134
    com.miHoYo.Yuanshen           10125 -> 10126
    com.exness.android.pa         10006 -> 10125

(The snapshot's uids are Android 17's, which is why the mapping has to come from
`packages.list` rather than from the snapshot.)

Verified afterwards:

    app 13G / data 24G / media 44G   — all match the snapshot
    all data + external uid ownership consistent

## Lesson

Do not `kill -9` the game process. Android treats that as a crash and reconciles
`/data/data`, discarding saves. Use the in-game restart (which did not need a
kill) or accept the wedged download, and if a kill is unavoidable, run
`fix-waydroid-container.sh` and restore from the snapshot afterwards.

---

# Container dies seconds after starting — root cause fixed 2026-09-16

## Symptom

Container exits ~30 s after launch, code 143 (SIGTERM), with:

    [22:28:36] Starting waydroid session
    [22:28:36] RuntimeError: Already tracking a session
    Gdk-Message: Error reading events from display: Broken pipe

## Root cause: a bug in Waydroid's own restart path

`tools/actions/container_manager.py` starts a session like this:

    def do_start(args, session):
        if "session" in args:
            raise RuntimeError("Already tracking a session")   # line 157
        ...
        args.session = session                                   # line 221

and `stop()` is the only place that clears it:

        if "session" in args:
            ...
            del args.session

But `restart()` called the LXC helpers **directly**, bypassing `stop()`:

    def restart(args):
        status = helpers.lxc.status(args)
        if status == "RUNNING":
            helpers.lxc.stop(args)
            helpers.lxc.start(args)
        else:
            logging.error("WayDroid container is {}".format(status))

so after a restart `args.session` stayed set. The container manager is a
long-lived process (started once from `20-waydroid-setup.sh`, owning the D-Bus
name `id.waydro.Container` for the container's whole life), so the next session
start then hit the guard and tore the session down within seconds.

This is not a corner case: the in-container netfix path runs
`waydroid container restart` on ordinary startups to recreate NetworkMonitor
(`scripts/startup.sh` line 407), so every startup that took that path left the
manager poisoned for the next one.

## Fix

Cleared the tracked session in `restart()`, matching `stop()`:

    def restart(args):
        status = helpers.lxc.status(args)
        if status == "RUNNING":
            helpers.lxc.stop(args)
            helpers.lxc.start(args)
            if "session" in args:
                del args.session
        else:
            logging.error("WayDroid container is {}".format(status))

`waydroid-163/tools` is copied to `/usr/lib/waydroid/tools` by the Dockerfile
(line 97), so the change is in the image. Verified after rebuild:

    $ grep -n "del args.session" /usr/lib/waydroid/tools/actions/container_manager.py
    270:            del args.session          <- stop() (pre-existing)
    300:            del args.session          <- restart() (added)

## Also verified before rebuilding

  * no stale waydroid processes anywhere,
  * no stale `wayland-N` sockets (the separate failure mode that gives
    "not a directory" at mount time),
  * no `lxc/waydroid/partial` marker,
  * config intact: gralloc=renderD129, 4 DRM mount entries, A13 image hashes
    unchanged, translator VDSO present,
  * game data intact: app 13G / data 24G / media 44G.

---

# Container dies 3 s after start — the D-Bus bus split 2026-09-16

## Evidence

Container lifetime: started 03:36:16, finished 03:36:19 (exit 143). In that
window:

    "Starting waydroid session"    x3
    "RuntimeError: Already tracking a session"  x2
    "Gdk-Message: Error reading events from display: Broken pipe"

but only **one** launch of the UI:

    [2026-09-16 04:36:19] [waydroid] Starting full Android UI
    [2026-09-16 04:36:19] [Sway] - Starting: `/usr/bin/waydroid show-full-ui`

So one `show-full-ui` produced three session-start attempts.

## Mechanism

`show-full-ui` -> `app_manager.maybeLaunchLater()`:

    try:
        tools.helpers.ipc.DBusSessionService()      # look for id.waydro.Session
        ...
        launchNow()
    except dbus.DBusException:
        logging.error("Starting waydroid session")   # <- the repeated line
        tools.actions.session_manager.start(args, launchNow, background=False)

It only falls into that `except` when the **session service is not on the bus it
is looking at** — and it then starts one, which collides with the container
manager's already-held session:

    def do_start(args, session):
        if "session" in args:
            raise RuntimeError("Already tracking a session")

The reason it is looking at the wrong bus: `startup.sh` starts a session bus
earlier in the run and exports `DBUS_SESSION_BUS_ADDRESS`, but gow's launcher
starts sway as

    dbus-run-session -- sway --unsupported-gpu

and `dbus-run-session` **always** creates a new bus, replacing the variable in
its children. Measured:

    $ export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/testbus
    $ dbus-run-session -- sh -c 'echo $DBUS_SESSION_BUS_ADDRESS'
    unix:path=/tmp/dbus-qxcnyVNcqI,guid=...        <- a different bus

So sway's `exec` runs `show-full-ui` on a bus with no Waydroid session service.

## First attempt was wrong

I first set `DBUS_RUN_SESSION_BUS_ADDRESS`, believing that made
`dbus-run-session` reuse an existing bus. Tested it: the child still received a
freshly created address, so that variable does nothing here. Reverted and
replaced with the fix below.

## Fix

Pin the UI launch to our own bus explicitly, rather than relying on inheritance:

    launcher env DBUS_SESSION_BUS_ADDRESS="$_waydroid_bus" /usr/bin/waydroid show-full-ui

with the same treatment for the single-app path. Verified present in the rebuilt
image.

## Note on the earlier restart() fix

The `del args.session` added to `restart()` in the previous section is still
correct and still needed — it fixes a separate path where
`waydroid container restart` (used by the in-container netfix step) left the
manager holding a session. Both bugs produce the same error string, which is why
they were easy to conflate:

  * `restart()` never cleared the session      -> fixed in container_manager.py
  * show-full-ui ran on the wrong D-Bus bus    -> fixed in startup.sh

---

# Waydroid session STOPPED — three sway compositors 2026-09-16

## What the D-Bus fix achieved

The previous fix worked: the log now shows

    [waydroid] Pinning show-full-ui to session D-Bus unix:path=/run/user/wolf/dbus-session-0,...

and `RuntimeError: Already tracking a session` is **gone** — the container stayed
up 13 minutes instead of dying in 3 seconds.

But `waydroid status` reported `Session: STOPPED`, and the log ended with:

    [ERROR] [wlr] [render/swapchain.c:98] No free output buffer slot

## Root cause: launcher() starts a compositor per call

`startup.sh` ran **once**, but `launcher` was invoked **3 times**:

    [Sway] - Starting: `/usr/local/bin/waydroid-oomguard`
    [Sway] - Starting: `/usr/local/bin/waydroid-apprestore`
    [Sway] - Starting: `env DBUS_SESSION_BUS_ADDRESS=... /usr/bin/waydroid show-full-ui`

and gow's `launcher()` does not merely exec its argument — with RUN_SWAY set it
**starts a sway compositor for whatever it is handed**:

    elif [ -n "$RUN_SWAY" ]; then
        echo -n "workspace main; exec $@" >> $HOME/.config/sway/config
        dbus-run-session -- sway --unsupported-gpu

So the two background helpers each spawned their own sway. Measured:

    1283 sway --unsupported-gpu
    1284 sway --unsupported-gpu
    1287 sway --unsupported-gpu

Three compositors raced over one output, the renderer stalled with
`No free output buffer slot`, and only the last sway carried the
`exec ... show-full-ui` line — so the UI never came up and the session ended
STOPPED. (The stray `kitty` that appeared in the logs is consistent with a sway
whose `exec` never resolved to waydroid.)

## Fix

Run the background helpers directly — they are plain daemons and need no
compositor:

    /usr/local/bin/waydroid-oomguard &
    /usr/local/bin/waydroid-apprestore &

`launcher` is now used only for the UI itself. Verified in the rebuilt image:

    $ grep -n "launcher " /opt/gow/startup-app.sh
    551:        launcher env DBUS_SESSION_BUS_ADDRESS="$_waydroid_bus" \
    554:        launcher /usr/bin/waydroid show-full-ui
    563:        launcher env DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    566:        launcher /usr/bin/waydroid app launch "${WAYDROID_APP_PACKAGE}"

The netfix step already ran in a plain subshell, which is correct.

## Session-bug tally

Three distinct defects all produced symptoms in the same area; all are now fixed:

  * `restart()` never cleared the tracked session  -> container_manager.py
  * show-full-ui ran on swing's D-Bus, not ours    -> startup.sh (bus pinning)
  * background helpers each started their own sway -> startup.sh (direct exec)
