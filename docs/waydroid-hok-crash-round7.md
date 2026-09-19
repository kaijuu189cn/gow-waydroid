# Honor of Kings — crash investigation (round 7)

## What this round settled

### 1. `ro.input.resampling = 0` is DISPROVEN

The hypothesis (touch resampling rewrites buffered input in place and corrupts
the `InputConsumer` object) was tested and it did not hold. Verification that
the fix was genuinely active, not merely staged:

```
guest: getprop ro.input.resampling  ->  0
init : [input] ro.input.resampling=0 staged (disable touch resampling)
```

and the crash reproduced **identically**:

```
tombstone_19:  Process uptime: 236s
               signal 0 (SIGSEGV), code -6 (SI_TKILL)
               #00 libinput.so  InputConsumer::hasPendingBatch()+0
               #01 libandroid_runtime.so  NativeInputEventReceiver::consumeEvents
               #03 libutils.so  Looper::pollInner
```

Same function, same offset, same ~236s. **Reverted** — the init script now
carries a note recording the negative result so it is not retried.

### 2. The log-access dialog is a CONSEQUENCE, not a cause — settled

In the caught session the entire log contained exactly **one**
`LogAccessDialogActivity` start, and it came **after** the fault:

```
12:43:42.937  E CRASH: signal 11 (SIGSEGV)  >>> com.tencent.tmgp.sgame
12:43:44.134  Forwarding signal 11
12:43:44.356  START android/com.android.internal.app.LogAccessDialogActivity
12:43:45.307  SGame_Activity: onCrashHandleStart
12:43:46.757  Process 3685 exited due to signal 11
```

Independent confirmation from the mechanism: the crashing process's main thread
was inside the tombstone writer reading logs —

```
#01 __dl_LogdRead
#02 __dl_android_logger_list_read
#03 __dl_dump_log_file
#04 __dl_engrave_tombstone_proto
```

— and reading logs is exactly what raises Android 13's consent dialog. The
game's crash reporter (CrashSight) collects logs for the report; the dialog is
how Android 13 gates that. **The crash causes the dialog.**

All the earlier work on dismissing that dialog was treating a symptom. The
auto-tap remains off by default in `waydroid-anrwait.sh`.

### 3. The dialog cannot be prevented — by design, not by misconfiguration

Confirmed from primary sources this round:

* [Google Issue Tracker 243904932](https://issuetracker.google.com/issues/243904932):
  "Android 13 shows an allow access dialog when an app that has READ_LOGS
  permission runs logcat command"
* [r/androidapps](https://www.reddit.com/r/androidapps/comments/10vz9t7/how_to_allow_device_logs_alltime_access_in/):
  "Because of the changes to app permission security on Android 13 it's **not
  possible to allow any apps persistent access** to all device logs"

Matches what was measured here: `pm grant` reports `granted=true` while the
runtime still refuses (`prot=signature`), no appop accepts `READ_LOGS` /
`android:read_logs` / `log_access`, and `pm disable` of the activity is refused
by PackageManager. The pre-grant is kept in `startup.sh` but its comment now
says plainly that it does **not** stop the dialog.

## The crash, consolidated (7 tombstones)

| tombstone | uptime | #00 |
| --- | --- | --- |
| 12 | 237s | `InputConsumer::consumeSamples` |
| 13 | 236s | `InputConsumer::consumeSamples` |
| 15 | 236s | `InputConsumer::hasPendingBatch` |
| 16 | 237s | `InputConsumer::hasPendingBatch` |
| 17 | 235s | `InputConsumer::consumeSamples` |
| 18 | 1434s | `InputConsumer::hasPendingBatch` |
| 19 | 236s | `InputConsumer::hasPendingBatch` |

* Always `InputConsumer`, reached either from the Java looper
  (`Looper::pollInner` -> `consumeEvents` -> `hasPendingBatch`) or from the
  batched path (`ViewRootImpl$ConsumeBatchedInputRunnable` -> `consumeBatch` ->
  `consumeSamples`). Both are member functions of the same object.
* Both crash at **+0**; from tombstone_19's rip bytes the entry code is
  `mov rax,[rdi+0x948] / cmp rax,[rdi+0x950] / setne` — i.e. `!mBatches.empty()`.
  `rdi` (`this`) sits in `[anon:scudo:primary]`, which is where the
  `InputConsumer` lives.
* `Process uptime ~236s` in 6/7, and the two sessions where battle start is
  known both died **~155-170s after `OnBattleStart`**.
* Not memory pressure: container has no memory limit, guest sees 24.5GB
  available, allocator steady at 60MB, Java heap `66% free, 10MB/31MB`.
* No allocator-detected corruption anywhere in logcat (no scudo / GWP-ASan
  reports), and no `Abort message` on any tombstone.
* Not my helper: the session that crashed under observation (120443, uptime
  1434s) never tapped anything, and the auto-tap was already disabled.
* Native x86_64 titles do not show it — Dota Underlords ran on the same image
  without this crash.

## Where that leaves it: the ARM translation layer

This is a **known class of Waydroid problem**, not something specific to this
build:

* [waydroid#702 "Most games don't work"](https://github.com/waydroid/waydroid/issues/702)
  — "most games I tried crash when I try to play them" under the ARM translator.
* [waydroid#1895](https://github.com/waydroid/waydroid/issues/1895) — false-positive
  anti-cheat triggering under Waydroid.
* [r/arknights](https://www.reddit.com/r/arknights/comments/1hrdn3/tech_help_waydroid_crashes_every_minute_or_so/)
  — "Waydroid crashes every minute or so", same translator context.

And the community's standard mitigation is to **switch translation layer**:

* [Switching libndk_translation to libhoudini fixes an app's crashes](https://b-log.to/tech-analysis/waydroid-arm-translation-fix/)
* [libndk vs libhoudini](https://deepwiki.com/casualsnek/waydroid_script/5.4-arm-translation-(libndk-and-libhoudini))
* [Switching translator fixes ARM apps freezing at 1000% CPU](https://xoofee.github.io/posts/2026/09/fix-waydroid-arm-apps-high-cpu-libndk/)

The mechanism fits the evidence: the game's anti-cheat (`libtersafe.so`,
`libtprt.so`, `libgamemaster.so` are all loaded) performs periodic memory
scanning and log collection during a match -- which is also what raises the
log-access dialog at that moment -- and under binary translation that activity
corrupts unrelated framework heap, with `InputConsumer` as the visible victim.

### Feasibility, verified this round

* `/opt/gow/waydroid-script` ships in the image, with `stuff/houdini.py`.
* Houdini **does** support arm64 on this image's ABI list:
  ```
  arm64_exe  -> /system/bin/houdini64
  arm64_dyn  -> /system/bin/houdini64
  ro.dalvik.vm.native.bridge = libhoudini.so
  lib64/arm64, lib64/libhoudini.so
  ```
* Its own README notes `libndk` "seems to have better performance than
  libhoudini **on AMD**" -- this host is AMD, so the current layer was the right
  *performance* choice; that says nothing about crash behaviour.
* The blob is fetchable: 71.6MB from the `supremegamers/vendor_intel_proprietary_houdini`
  mirror, via GitHub, which responds 200 from here. Download is slow
  (~58 KB/s) and codeload does not support byte ranges, so it needs one clean
  full download rather than resume.

## Options from here

| Option | Cost | Risk | Notes |
| --- | --- | --- | --- |
| Switch `libndk` -> `libhoudini` | medium | **high** — it changes ARM behaviour for every app, and audio/online mode currently work only on this layer | the one community-backed fix for this crash class |
| Update/downgrade `libndk_translation` | low | medium | cheaper to try; different translator build may not corrupt the same way |
| Different Android image (A11) | high | high | re-opens every issue already fixed in this project |
| Accept the limitation | none | none | the game is playable in ~2.5-minute stretches |

Recommendation: try the **translator version change first** (cheap, reversible),
and treat the full `libhoudini` swap as the fallback. Either way it needs a
match played to confirm, and the current layer's working pieces (audio, online
mode, GPU) must be re-checked afterwards.

## Image state after this round

```
resampling change        reverted (negative result recorded inline)
log-access auto-tap      off by default
READ_LOGS pre-grant      kept, comment corrected (does not stop the dialog)
overlay index=off        OK
audio HAL shadow         OK
waydroid binary          OK
```

---

# Houdini escape hatch — implemented and ENABLED

## What was found while preparing it

The "cheaper option" from the table above turned out to be a no-op and was
dropped: the running translator already **is** `libndk_translation 0.2.3`,
which is exactly the version `waydroid_script` installs for Android 13.

```
guest : getprop ro.ndk_translation.version      -> 0.2.3
ndk.py: ro.ndk_translation.version = "0.2.3"
```

So there is no version to change to. Houdini is the only remaining
community-backed option.

## What was implemented

Houdini is vendored into the image but **inert by default**; the default
translator is untouched.

* `build/houdini/libhoudini.zip` (71.6 MB) -> `/opt/gow/houdini/libhoudini.zip`
  in the image. Verified md5 `37fe0899f1e4da7f9a724cca1c1ab1ea`, matching
  `stuff/houdini.py`'s expected value for the Android 13 archive.
* New init section **4j** in `20-waydroid-setup.sh`. Gated on
  `WAYDROID_ARM_TRANSLATOR=libhoudini`:
  - extracts only the `prebuilts/` subtree (which is the `/system` content:
    `bin/`, `etc/`, `lib/`, `lib64/`) into `${WAYDROID_WORK}/overlay/system/`
  - points `ro.dalvik.vm.native.bridge` at `libhoudini.so` in `waydroid.cfg`,
    `waydroid_base.prop` and `waydroid.prop`
  - logs `[arm] translator: libhoudini (ro.dalvik.vm.native.bridge=libhoudini.so)`
    or `[arm] translator: libndk_translation (default; ...)` every boot, so which
    bridge is active is never ambiguous.
* The overlay lives on the data volume, so the 208 MB extraction happens **once**,
  not on every container start.

Extraction was verified in isolation, without touching the running session:

```
extracted files: 650
  OK   bin/houdini
  OK   bin/houdini64
  OK   lib64/libhoudini.so
  OK   lib/libhoudini.so
  OK   etc/init/houdini.rc
arm64 libs: 323
size: 208M
```

## Enabled

`waydroid.cfg`-side config is not what selects the translator, so the env var was
added to both Waydroid app entries in Wolf's config:

```
env = [ 'GOW_REQUIRED_DEVICES=...', 'WAYDROID_IMAGE_TYPE=VANILLA',
        'RUN_SWAY=false', 'WAYDROID_ARM_TRANSLATOR=libhoudini' ]
```

Backup: `/etc/wolf/cfg/config.toml.bak-houdini-140848`

Wolf **caches app definitions at startup** (verified: the edit did not appear in
`GET /api/v1/apps` until it was restarted), so Wolf was restarted. Confirmed
loaded:

```
Waydroid -> ['RUN_SWAY=false', 'WAYDROID_ARM_TRANSLATOR=libhoudini']
```

## How to test

1. Reconnect from Moonlight. The container extracts Houdini and boots Android
   with it; check the log line `[arm] translator: libhoudini`.
2. Play a match and get past **~155s after `OnBattleStart`** — the point every
   previous attempt died at.

Confirm the bridge really switched:

```bash
docker exec <cid> lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- \
  sh -c 'getprop ro.dalvik.vm.native.bridge'      # expect libhoudini.so
```

## How to revert (one line, takes effect after a Wolf restart)

```bash
docker exec wolf sed -i "s/, 'WAYDROID_ARM_TRANSLATOR=libhoudini'//" /etc/wolf/cfg/config.toml
docker restart wolf
# or restore wholesale:
docker exec wolf cp /etc/wolf/cfg/config.toml.bak-houdini-140848 /etc/wolf/cfg/config.toml
```

The extracted Houdini files stay in the overlay but are simply not used once
`ro.dalvik.vm.native.bridge` points back at `libndk_translation.so`. Removing
them is optional (`rm -rf /data/waydroid/overlay/system/{bin,etc,lib,lib64}` is
NOT safe -- that tree also holds the libndk payload).

## What to re-verify after switching

Houdini does not use libndk's EGL/GLES proxy libraries, so graphics goes through
a different path. Re-check the three things that currently work:

* rendering (no 花屏, no black screen)
* audio (**the real audio HAL over the stub** -- this was a separate fix, but
  the ARM64 AAudio proxies in the overlay belong to libndk, so audio is the
  most likely casualty)
* online mode (anti-cheat behaves differently under a different translator --
  it may be better or worse)

If any of those regress, revert; if the crash disappears and they hold, the
translator was the cause.
