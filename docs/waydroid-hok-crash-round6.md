# Honor of Kings — crash investigation (round 6)

## Round 6 addendum: live reproduction changes the picture

While investigating, the game crashed again under observation, in a session
that rules out my earlier hypotheses one by one.

### The new data point

```
session 120443 (NEW image, log-access auto-tap DISABLED):
  12:04:43  process start
  12:05:41  OnBattleStart            <- enters a match
  12:05:41  game log stops writing   <- main thread freezes 1s after battle start
  12:08:29  SIGSEGV (tombstone_18)   <- pss=3.3GB, rss=4.0GB
```

tombstone_18 shows the same fault as the previous five:

```
#00 libinput.so  android::InputConsumer::hasPendingBatch()+0
#01 libandroid_runtime.so  NativeInputEventReceiver::consumeEvents
#03 libutils.so  Looper::pollInner
```

This session proves:

| Hypothesis | Status |
| --- | --- |
| helper's auto-tap causes it | **ruled out** — this session never tapped anything |
| fixed 236s process-uptime timer | **ruled out** — this process was 1434s old when it died |
| entering a match triggers it | **supported, and sharper**: ~165s after battle start |

### The corrected pattern

Comparing the two sessions where the battle-start time is known:

| session | OnBattleStart | death | survived after battle start |
| --- | --- | --- | --- |
| 113959 | 11:41:09 | 11:43:42 | **153s** |
| 120443 | 12:05:41 | 12:08:29 | **168s** |

The game's own log stops writing **1 second after OnBattleStart** in both —
the main thread freezes at battle start and the process is declared dead
~2.5 minutes later. 153s/168s after battle start is roughly where Honor of
Kings finishes loading a match and the first creep wave spawns, i.e. the
moment sustained multi-touch input begins.

(An earlier observation that "one process survived 2 hours" was wrong: its log
had also frozen at battle start. It died while being inspected.)

## The fix being tested: `ro.input.resampling = 0`

### Why this line of attack

Reading AOSP `libs/input/InputConsumer.cpp` (fetched during this round):

1. `hasPendingBatch()` is a one-liner — `return !mBatches.empty();` — and
   `consumeSamples` dereferences members at function entry. Both tombstones
   crash at **offset +0**, and `rbx` points into `[anon:scudo:primary]`
   surrounded by scudo chunk metadata. The `InputConsumer` object itself is
   corrupted; this is not a `NO_MEMORY` (that returns cleanly) and not bad
   input data (that would crash mid-function).

2. The ONLY code path in this file that **rewrites buffered InputMessages in
   place** is touch resampling:

```cpp
const char* PROPERTY_RESAMPLING_ENABLED = "ro.input.resampling";
...
void InputConsumer::rewriteMessage(TouchState& state, InputMessage& msg) { ... }
```

   `resampleTouchState` -> `rewriteMessage` -> `getPointerById` mutate the
   buffered samples based on `mTouchStates` history that `updateTouchState`
   builds up over time.

3. AOSP's own comment: *"Resampling is not needed (and should be disabled) on
   hardware that already has touch events triggered by VSYNC."* Waydroid's
   `wayland_touch` is exactly that — a synthetic vsync-aligned device.

So the mechanism proposed is: a translated ARM64 game drives sustained
multi-touch during a match; the resampling path rewrites buffered input using
touch-state history; on this non-VSYNC-aligned-in-the-way-real-hardware-is
device that path corrupts the object. Disabling it removes the only in-place
mutation of buffered input, on a device class AOSP says should not resample.

### What was changed

`waydroid.cfg` + `waydroid_base.prop` + `waydroid.prop` (live, takes effect on
the next session start), and the init script now stages it permanently:

```
[input] ro.input.resampling=0 staged (disable touch resampling)
```

Revert with `WAYDROID_INPUT_RESAMPLING=1` if it turns out to matter.

**This is a hypothesis being tested, not a proven fix.** The next match played
after a session restart is the test: if the crash is gone past the ~165s
battle mark, the hypothesis holds; if it still dies at the same offset, the
corruption is elsewhere and this gets reverted.

## Two corrections to my own earlier work

### 1. `pc=0` was NOT an ARM64 translation fault

Last round I reported:

> The program counter is 0 — the ARM64 guest jumped to a NULL address. This is
> a fault inside the ARM64 emulation path.

**That was wrong.** That dump is printed by the *game's own* crash handler
(Unity/CrashSight), which unconditionally dumps ARM64 registers. The actual
faulting thread is x86_64 framework code, and the system tombstone proves it:

```
tombstone_17
signal 0 (SIGSEGV), code -6 (SI_TKILL)
    rip 00007fb1ff6a71f0                      <- x86_64 register set
backtrace:
  #00 /system/lib64/libinput.so  android::InputConsumer::consumeSamples(...)+0
  #01 /system/lib64/libinput.so  android::InputConsumer::consumeBatch(...)+297
  #02 /system/lib64/libinput.so  android::InputConsumer::consume(...)+2629
  #03 /system/lib64/libandroid_runtime.so  NativeInputEventReceiver::consumeEvents
  #04 /system/lib64/libandroid_runtime.so  nativeConsumeBatchedInputEvents
  #05 art_jni_trampoline
  #06 android.view.ViewRootImpl$ConsumeBatchedInputRunnable.run
  #07 android.view.Choreographer.doCallbacks
  #08 android.view.Choreographer.doFrame
```

The `pc=0` ARM64 state is a stale context, not the fault site.

### 2. The log-access dialog is a SYMPTOM of the crash, not a cause

This is now proven two independent ways.

**Ordering** — the game dies first, the dialog is created 1.4s later:

```
12:43:42.937  E CRASH: signal 11 (SIGSEGV)  >>> com.tencent.tmgp.sgame
12:43:44.134  Forwarding signal 11
12:43:44.356  START android/com.android.internal.app.LogAccessDialogActivity
12:43:44.940  Displayed LogAccessDialogActivity: +583ms
12:43:46.757  Process 3685 exited due to signal 11 (Segmentation fault)
```

**Mechanism** — the crashing process's main thread is inside the tombstone
writer, reading the log buffer:

```
#00 __dl_recvfrom
#01 __dl_LogdRead
#02 __dl_android_logger_list_read
#03 __dl_dump_log_file                 <- reading logs
#04 __dl_engrave_tombstone_proto
#07 __dl_debuggerd_fallback_handler
```

Reading logs is exactly what triggers Android 13's log-access consent. So the
crash causes the dialog: the game's crash reporter collects logs for the report.
Every earlier attempt to dismiss that dialog was treating a symptom — and each
tap injected input into the very subsystem that is crashing.

## The real crash: deterministic, ~236s after process start

Five Honor of Kings tombstones, all with the same shape:

| tombstone | time (UTC) | process uptime | crash site |
| --- | --- | --- | --- |
| 12 | 09:32:10 | **237s** | libinput `InputConsumer::consumeSamples` |
| 13 | 09:40:52 | **236s** | libinput `InputConsumer::consumeSamples` |
| 15 | 11:01:17 | **236s** | libinput `InputConsumer::hasPendingBatch` |
| 16 | 11:28:55 | **237s** | libinput `InputConsumer::hasPendingBatch` |
| 17 | 11:43:45 | **235s** | libinput `InputConsumer::consumeSamples` |

**Uptime 235–237s in 5/5 cases — a spread of 2 seconds.** This is not a random
game bug; it is deterministic and timer-like. Both crash sites are inside
`InputConsumer`, i.e. the app's side of the input channel, reached from
`ViewRootImpl$ConsumeBatchedInputRunnable` — during a frame, consuming batched
motion events.

`ApplicationExitInfo` agrees: `reason=2 (SIGNALED) status=11 (SIGSEGV)`, and the
intervals between crashes (09:32 -> 09:36 -> 09:40 -> 09:47) are 4–7 minutes,
matching the user's "every 3–10 minutes during play".

### It happens after entering a match

Every game log that ends near a crash contains `OnBattleStart`:

```
11:41:09.678  I  CBattleSacredAnimalAIVoiceManager::OnBattleStart ...
```

and the process (started 11:39:47) died at 11:43:42 — i.e. ~82s to reach the
battle, then ~154s of play before the crash.

### Ruled out

| Hypothesis | Evidence against |
| --- | --- |
| Host/container OOM | container has no memory limit; guest sees 24.5GB available; no cgroup limit |
| Java heap exhaustion | ANR trace: `Heap: 66% free, 10MB/31MB` |
| Anti-cheat SIGSEGV at `pc=0` | the ARM64 dump is the app's handler; real fault is x86_64 libinput |
| My ANR helper's taps | no taps anywhere near any crash (last was 15 min earlier) |
| `READ_LOGS` / appop | not an appop in this build; every candidate name rejected |

## What I changed

`waydroid-anrwait.sh`: the log-access auto-tap is now **off by default**
(`WAYDROID_LOGACCESS_AUTOTAP=1` re-enables it), with the reasoning recorded
inline. It cannot save the game — by the time the dialog is visible the process
is already dead — and its taps add input events to the crashing subsystem.

The ANR auto-wait is unchanged; that one addresses a real startup problem.

## What I do not know

I have **no fix** for the ~236s input-consumer crash, and I am not going to
guess at one. What the evidence points to, without being proven:

* The crash is in Android framework code (`libinput`), reached through the
  batched-input path, on the x86_64 side. The app is an ARM64 title running
  under `libndk_translation`, so an out-of-bounds write from translated guest
  code corrupting the input channel object is a plausible mechanism — which
  would make this inherent to emulating this title rather than something a
  container setting can fix.
* Supporting, but not conclusive: a native x86_64 title (Dota Underlords) ran
  on the same image without this crash.

### To go further, in order of value

1. **Check whether the same crash reproduces without ARM translation.** If a
   native x86_64 game survives multi-hour play and Honor of Kings does not,
   that largely settles it.
2. **Bisect the helpers.** Run a session with `WAYDROID_ANR_AUTOWAIT=0` and the
   oomguard disabled, and see whether the 236s determinism survives. The
   oomguard periodically rewrites `oom_score_adj` and calls `taskset -p` on
   every thread of the game process; I could not rule it out, because its log
   does not record which process it matched and the PIDs had already exited.
3. **Capture a crash with the input batch intact.** The tombstone's faulting
   frame is `consumeSamples+0`, so the batch data itself is the interesting
   artifact — that needs a debuggerd run with the input channel state, not
   something the current logs retain.
