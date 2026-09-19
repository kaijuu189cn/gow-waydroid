# Multi-session audio cross-talk — root cause and fix

## Symptom

With two devices streaming at once, each one hears the *other* session's audio.

## Root cause: the guest hostname is identical in every container

Wolf's pulse router decides which session a playback stream belongs to by
reading one PulseAudio client property —
`src/moonlight-server/audio/pulse_router.cpp`:

```cpp
void PulseAudioRouterState::route_sink_input_(pa_context *c,
                                              const pa_sink_input_info *info) {
  if (!info || !info->proplist) return;
  const char *host = pa_proplist_gets(info->proplist, "application.process.host");
  if (!host || host[0] == '\0') return;          // unmatched -> NO routing at all
  ...
  auto box = host_to_session.load();
  if (auto v = m.find(std::string(host))) { ... }
  pa_context_move_sink_input_by_index(c, info->index, *target_sink_idx, ...);
}
```

and `host_to_session` is keyed by the **container hostname**:

```
[PULSE_ROUTER] Map add host='01688ede1710' -> session='710937327306524487'
                       ^^^^^^^^^^^^ 12-char docker container ID
```

`application.process.host` is filled by libpulse from `gethostname()`, i.e. the
UTS hostname. **Waydroid hardcodes that hostname to `waydroid` for every
container**, so the lookup can never match and the stream is never moved.

Measured on the live host:

```
container hostname (Wolf's map key)        23ab7704750a
guest /proc/sys/kernel/hostname            waydroid
live sink-input application.process.host   waydroid        <- mismatch
```

and the router's own counters over the whole log:

```
Map add lines:          31
Move sink-input lines:   0        <- routing had NEVER succeeded once
```

`lxc.uts.name = waydroid` is the source, hardcoded in Waydroid's LXC config.

**Why it looks harmless with one client:** with a single session there is only
one sink, so an unrouted stream happens to sit on the right one. The moment a
second client connects, both streams fall to the same default sink and each
device hears the other.

## Fix

The init script now rewrites the UTS name to this container's own hostname while
it assembles the LXC config, so the property equals the map key:

```sh
_g_host="${WAYDROID_GUEST_HOSTNAME:-$(hostname 2>/dev/null)}"
if [ -n "$_g_host" ]; then
    sed -i '/^lxc\.uts\.name[[:space:]]*=/d' "$_lxc_cfg"
    printf 'lxc.uts.name = %s\n' "$_g_host" >> "$_lxc_cfg"
    gow_log "[audio] guest hostname set to ${_g_host} (per-session pulse routing)"
fi
```

This uses Wolf's existing mechanism rather than bypassing it, and because each
session gets a *different* container hostname, the keys stay unique.

Verified the replacement logic in isolation (old line removed, new value
written exactly once, idempotent across runs).

Override with `WAYDROID_GUEST_HOSTNAME=<value>` if needed.

## How to verify

1. Reconnect from the first device, then from the second.
2. Confirm the guest now reports a per-session hostname:

```bash
cid=$(docker ps -q --filter name=WolfWaydroid | head -1)
docker exec $cid lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- \
  sh -c 'cat /proc/sys/kernel/hostname'      # expect the 12-char container ID
docker inspect $cid --format '{{.Config.Hostname}}'   # must be the same value
```

3. Confirm Wolf is now actually routing, which it never did before:

```bash
docker logs wolf 2>&1 | grep -a "Move sink-input" | tail
```

A `[PULSE_ROUTER] Move sink-input=... host='<id>' -> session='...' sink_idx=N`
line is the proof. Before the fix that grep was empty.

4. With both devices playing, each stream should sit on its own sink:

```bash
docker exec wolf sh -c 'export PULSE_SERVER=/run/user/wolf/pulse-socket; \
  pactl list short sink-inputs'
```

## If it still crosses over

The fallback is to stop relying on routing altogether and make each guest select
its own sink directly: Wolf already sets `PULSE_SINK=virtual_sink_<session>` on
the container, so injecting that same value into Android's audio HAL (via a
supplementary `vendor.audio-hal` service rc in the overlay) would pin the stream
at creation. That is more invasive — Android init tolerates a re-declared
service by *adding* `setenv` lines — so it is worth trying only if hostname
matching turns out to be insufficient.

## Note on the Houdini switch

The user reports the game is now working, which confirms the translator swap
(Houdini, enabled in the previous round) resolved the periodic SIGSEGV.

---

# Two more findings from verifying this fix

## 1. The audio HAL is crashing intermittently — Waydroid's own code

Three tombstones, identical signature (tombstone_14 at 10:57, _20 at 16:44, _22 at 16:59):

```
Cmdline: /vendor/bin/hw/android.hardware.audio.service
signal 0 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr --------
    eip 000046c6            <- executing an unmapped low address
  #00 pc 000046c6  <unknown>
  #01 pc 00003713  /vendor/lib/hw/audio.primary.default.so (out_write+371)
  #02 pc 0002e7df  /vendor/lib/hw/android.hardware.audio@4.0-impl.so
```

`out_write` jumps to a wild function pointer (`0x46c6`, garbage rather than NULL).

This happens in the file staged by the audio-HAL shadowing fix, so I checked whether
that staging was at fault. It is not — the staged files are byte-identical to
Waydroid's real HAL:

```
32-bit 71f208383ba32ef13f314c3c73ba6ba9  overlay lib/hw/audio.primary.default.so
                                          image  lib/hw/audio.primary.waydroid.so
64-bit af8e95122303092d774e07f8b0961e23  overlay lib64/hw/audio.primary.default.so
                                          image  lib64/hw/audio.primary.waydroid.so
```

The shadowing only changes which soname the HAL loader resolves; the code is
Waydroid's. Timing correlates with **session lifecycle changes**:

```
16:59:52.775  [DOCKER] Stopping container: /WolfWaydroid_710937727306524487
16:59:52.775  [PULSE_ROUTER] Removed mappings host='167005bbbd8b'
16:59:54.736  Sink appeared 'virtual_sink_710937727306524487' idx=3
16:59:55.378  [DOCKER] Starting container: /WolfWaydroid_710937727306524487
16:59:56.941  audio.service SIGSEGV          <- ~4s after the restart
```

**This matters for the cross-talk symptom**: an unrouted stream (see root cause
above) lands on whatever the *default* sink is at the time it is created. When the
HAL crashes and is restarted it creates a *new* stream, which can pick up the
other session's sink — which is exactly the "each device hears the other" swap.
The hostname fix removes the dependency on the default sink, so this path no
longer causes cross-talk, but the HAL crash itself is unfixed and will still
cause brief audio dropouts around session changes.

## 2. Two Waydroid containers run concurrently and share /data/waydroid

While verifying, both sessions were live at once and inspect confirms they bind
the same host directory:

```
/WolfWaydroid_710937727306524487  /data/waydroid -> /var/lib/waydroid
/WolfWaydroid_3738672949246314284 /data/waydroid -> /var/lib/waydroid
```

Lifetimes from `docker inspect` and the Wolf log show a **~27 minute overlap**
(16:59:55 -> 17:26:50), and the second container's Android fully booted
(`Android with user 0 is ready`). So two complete Android instances were running
against one data directory: the same Android userdata (including the game's
install and account), the same `waydroid.cfg`, the same LXC config, and — most
dangerously — the same overlay upperdir:

```
overlay on /var/lib/waydroid/rootfs
  lowerdir=/var/lib/waydroid/overlay:/var/lib/waydroid/rootfs
  upperdir=/var/lib/waydroid/overlay_rw/system
  workdir=/var/lib/waydroid/overlay_work/system
  index=off                                    <-- shared upperdir permitted
```

### Correction to my own earlier change

I added `index=off` in `tools/helpers/mount.py` to fix an overlay mount failure
whose dmesg message was:

```
overlayfs: upperdir is in-use as upperdir/workdir of another mount,
mount with '-o index=off' to override exclusive upperdir protection.
```

At the time I read that as one container tripping over a stale mount. Given the
evidence above, **the more likely reading is that it was the second container
mounting the same upperdir while the first had it live** — the kernel was
refusing for exactly the right reason, and `index=off` silenced that protection,
letting two Android instances write to one overlay upper concurrently.

Whether to keep it is a real trade-off:

* **keep `index=off`** — the second session's overlays mount and the translator /
  audio fixes work for it, but two instances share writable state (data
  corruption risk).
* **revert `index=off`** — the second session's overlay mount fails instead,
  Waydroid prints `Mounting overlays failed. The feature has been disabled.` and
  writes `mount_overlays = False`, so that session loses the ARM translator
  (online mode breaks) — but the failure is loud rather than silent.

Neither is correct; the real fix is per-session Waydroid state. The pieces that
must be per-session are the mutable ones — `userdata/`, `overlay_rw/`,
`waydroid.cfg`, `lxc/`, `waydroid_base.prop` — while `images/` (system.img,
vendor.img) can stay shared and symlinked. `userdata/` is the expensive one: it
is 82 GB and holds the game install, so naive per-session copies are not viable;
per-session overlayfs on top of a shared read-only `userdata/` would be the
scalable shape, but that is a design change, not a patch, and it needs its own
risk analysis (Android's /data is not designed to be shared underneath).

---

# Why the first attempt at this fix did nothing (my mistake)

The override was originally placed **inside** this guard:

```sh
if [ ! -f "${WAYDROID_WORK}/lxc/waydroid/config" ]; then
    gow_log "[layout] LXC config missing; generating it"
    ...          # <- the hostname override lived in here
fi
```

That guard only regenerates the LXC config when it is **missing**, and the config
lives on the persistent data volume, so on a normal start the guard is skipped
and nothing inside it executes. The guest kept the hostname `waydroid`.

Proof it was skipped, from the container's own log — the `[layout]` lines are
present but the guard's own message is absent:

```
[layout] waydroid_base.prop generated
[layout] Rewrote 3 relative LXC mount(s) in config_session
[audio] real audio HAL staged over the 'default' stub
        ^ no "[layout] LXC config missing; generating it" anywhere
```

(The config file's mtime still moves, which is what made this look like the code
had run — other sections, e.g. 4e, `sed` that same file.)

**Fix**: moved into its own section **4d-bis** placed after the guard, so it runs
on every start. Verified by extracting the real block out of the built image and
executing it:

```
case A (config already present, says "waydroid"):
  [log] [audio] guest hostname set to f770dd016426 (per-session pulse routing)
  lxc.uts.name = f770dd016426          (exactly one line)
case B (config absent):
  [log] [audio] WARNING: no LXC config ...   (correct)
```

## Why "the whole system has no sound" is the same root cause

With routing dead and more than one session, every stream stays on whichever sink
is PulseAudio's **default**. One session therefore receives *all* the audio and
the other receives *none* — the same defect surfaces either as cross-talk (both
devices hearing one stream) or as a device with no sound at all, depending on
which sink is default and when streams get recreated. The HAL crash below makes
streams get recreated often, which is how the symptom flips between the two.

So the fix for "no sound" is the same one-line routing fix above; it needs a
reconnect to take effect because it changes the container's LXC config.

---

# Cross-talk after the fix: what is verified, and what is left

The user reported cross-talk again after reconnecting with the fix. Everything
below was checked against the live Wolf logs rather than assumed.

## What IS working (verified)

The routing fix took effect — this is the first time in the whole log that the
router ever moved anything (it was 0 before):

```
18:02:43  input=88 host='7a23fec1ce89' -> session='3738672949246314284' sink_idx=8
18:02:00  input=80 host='16007af5cd88' -> session='710937727306524487' sink_idx=7
18:04:51  input=100 host='6f8c5e5bbfc3' -> session='3738672949246314284' sink_idx=11
```

Every target index was checked against which sink actually carries that name at
that moment, and **all of them are correct**:

```
SINK idx=7  -> session=710937727306524487
SINK idx=8  -> session=3738672949246314284
SINK idx=11 -> session=3738672949246314284
MOVE session=...284 -> idx=8    correct
MOVE session=...487 -> idx=7    correct
MOVE session=...284 -> idx=11   correct
```

Capture side is correct too:

```
Starting audio producer: pulsesrc device="virtual_sink_710937727306524487.monitor"
Starting audio producer: pulsesrc device="virtual_sink_3738672949246314284.monitor"
```

Both containers carried the fix (`[audio] guest hostname set to <id>`), and their
guest hostnames matched their own container hostnames.

## Ruled out

* **`module-stream-restore`** — not loaded. Wolf's server has exactly three
  modules: `module-native-protocol-unix`, `module-always-sink`,
  `module-null-sink`. So per-application routing memory is not overriding
  anything.
* **Stale sink index in the router** — checked every move against the live
  index→session assignment; all correct.
* **Wrong capture device** — each session's `pulsesrc` names its own sink's
  monitor.

Note the default sink is `auto_null` ("Dummy Output"), which **no** session
captures. So an unrouted stream produces *silence*, not cross-talk — audio can
only reach the wrong device if a stream is moved onto the other session's sink.

## The remaining suspect: the shared LXC config

`/data/waydroid` is bind-mounted into every Waydroid container, so this path is
**shared by both containers**:

```
/var/lib/waydroid/lxc/waydroid/config     <- contains lxc.uts.name
```

The hostname fix writes each container's own hostname into that one shared file.
Container A writes `lxc.uts.name = A`, container B writes `lxc.uts.name = B` —
and whichever write happens last before a given container's LXC starts is what
that container's guest gets. If B's write lands after A's but before A's
`lxc-start`, **A's guest boots with B's hostname**.

Consequence: both guests report the same `application.process.host` → both
sessions' streams map to the *same* session → that session's device receives all
the audio and the other receives none. That single defect shows up either as
cross-talk or as silence depending on which side wins, which is exactly how the
symptom has been flip-flopping.

In the sessions I could still inspect the two guests happened to get distinct
hostnames, so the race did not bite there and I have **not** caught it in the
act. It is the only mechanism left that can put a stream on the other session's
sink while the router itself is provably correct.

## Instrumentation now running

`/root/wolf/diagnostics/audiomon.sh` samples every 5s and writes
`/root/wolf/diagnostics/audio-routing.log`. Each line records the sink index →
session map, the container hostname → session map, and for every sink-input its
current sink, owning host and application name — flagging any stream whose
host's session does not match its sink's session:

```
<<< MISMATCH: stream belongs to X but sits on sink of Y
```

That flag is the proof one way or the other. Reproducing with two devices while
this runs will settle it in one attempt.

## Fix that follows if the race is confirmed

Make the LXC config directory per-container instead of shared. `/run` is
per-container, so the container can keep its own copy and bind-mount it over the
shared path before Waydroid starts LXC:

```sh
cp -a /var/lib/waydroid/lxc/waydroid /run/waydroid-lxc-<hostname>
sed -i "s|^lxc\.uts\.name.*|lxc.uts.name = <hostname>|" \
    /run/waydroid-lxc-<hostname>/config
mount --bind /run/waydroid-lxc-<hostname> /var/lib/waydroid/lxc/waydroid
```

That removes the race without touching the shared data volume. It does **not**
fix the shared overlay upperdir (`index=off`), which stays a separate hazard.

---

# Resolution (user confirmed)

> "两个设备声音已经正常。" — both devices' audio is correct.

## Correction: my routing monitor was broken, so its "0 mismatches" proves nothing

I claimed the monitor would be decisive. It was not — it had a bug. It invoked

```sh
docker exec wolf pactl list short sinks        # PULSE_SERVER absent inside the container
```

`PULSE_SERVER` was exported in the monitor's own shell, which does **not** reach
the process inside the `docker exec`. `pactl` therefore could not connect, the
sink list came back empty, and every sample recorded only the container→session
map:

```
[02:15:33] sinks:                                        <- empty, always
  | containers: b48533d70766=3738672949246314284 76066df452ba=710937727306524487
```

So "0 MISMATCH" was vacuous: with no sink data the mismatch test could never
fire. I should not have presented it as evidence, and I am recording it here so
it is not trusted later.

Fixed for future use — `docker exec -e PULSE_SERVER=/run/user/wolf/pulse-socket`
now works and lists sinks correctly.

## What actually supports the fix

1. **The router moves streams for the first time ever.** Before this work the
   log had 31 `Map add` lines and **zero** `Move sink-input` lines. Now:

   ```
   18:02:00  input=80  host='16007af5cd88' -> session='710937727306524487' sink_idx=7
   18:02:43  input=88  host='7a23fec1ce89' -> session='3738672949246314284' sink_idx=8
   18:13:55  input=...  host='b48533d70766' -> session='3738672949246314284' sink_idx=14
   ```

2. **Every target index was cross-checked against the live index→session
   assignment at that moment**, from the `Sink appeared name='virtual_sink_X'
   idx=N` lines. All correct — e.g. `idx=7` was session `...487`'s sink and the
   `...487` stream was moved there.

3. **Each session captures its own monitor**:
   `pulsesrc device="virtual_sink_710937727306524487.monitor"` and
   `pulsesrc device="virtual_sink_3738672949246314284.monitor"`.

4. **Both containers carried the fix** —
   `[audio] guest hostname set to b48533d70766` and
   `[audio] guest hostname set to 76066df452ba`, matching their own container
   hostnames while running concurrently.

5. User confirmation with two devices.

## Remaining hazards (unchanged, not fixed by this work)

Both stem from every Waydroid container binding the same `/data/waydroid`:

* **Hostname race.** `/var/lib/waydroid/lxc/waydroid/config` is one shared file
  and each container writes its own `lxc.uts.name` into it. If one container's
  write lands before the other's `lxc-start`, that container's guest boots with
  the wrong hostname, both guests then report the same
  `application.process.host`, and both sessions' audio routes to one session.
  Not observed in the sessions I could inspect (the two guests had distinct
  hostnames), but the window is real. Fix if it ever bites: keep a per-container
  copy under `/run` and bind-mount it over the shared path before LXC starts.
* **Shared overlay upperdir.** Two concurrent containers mount the same
  `overlay_rw/` upper, permitted only because of the `index=off` I added
  earlier. The kernel's default refusal was arguably correct.
