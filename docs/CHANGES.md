# Waydroid app — consolidated change list and rollback guide

Everything below was re-verified against the files on disk before writing this
list; nothing here is from memory. Repository root is
`gow-master/apps/waydroid/build` unless stated otherwise.

Two things to know up front:

* **The repo is not a git checkout** (`git rev-parse` fails), so there is no
  `git diff` / `git checkout` rollback. Each change is reverted by hand, and the
  exact edit is given below.
* **Wolf caches app definitions at startup.** Any change to Wolf's
  `config.toml` needs `docker restart wolf`. Changes inside the *image* do not —
  Wolf creates a fresh container per session, so a reconnect picks them up.

---

## 1. Image changes (files in the repo)

Rebuild after editing any of these:

```bash
cd /root/wolf/gow-master/apps/waydroid/build
docker build --build-arg BASE_APP_IMAGE=ghcr.io/games-on-whales/base-app:edge \
  -t gow-waydroid:latest .
```

Last built image: `gow-waydroid:latest` = `762d09061ec4` (1.86 GB).

> The build **requires BuildKit**. The legacy builder (`DOCKER_BUILDKIT=0`)
> silently skips the `RUN <<_INSTALL_...` heredocs and produces an image with no
> `/usr/bin/waydroid`, which then exits 127. That failure mode already bit us
> once. BuildKit comes from `docker-buildx-plugin`.

### 1.1 `overlay/etc/cont-init.d/20-waydroid-setup.sh` — the bulk of the work

This one script holds most of the fixes, as numbered sections:

| Section | What it does | Why |
| --- | --- | --- |
| §2b | Repoints the binder device to `/dev/binderfs/anbox-binder` (242,1) | binder had no usable node; nothing could talk to system_server |
| §4b | Repairs the `/var/lib/waydroid` layout | images placed by hand leave the tree incomplete |
| §4c | Regenerates `waydroid_base.prop` when out of sync | guest props otherwise drift from `waydroid.cfg` |
| §4d | Generates the LXC config when missing | `lxc-start` has nothing to boot otherwise |
| **§4d-bis** | **Sets `lxc.uts.name` to this container's hostname** | **audio isolation — see §3** |
| §4e | Makes the LXC `dev` mount entry absolute | relative entry fails to mount |
| §4f | Gives Android the DRM card node, not just the render node | render-node-only breaks the HALs |
| §4g | Single-GPU pinning: derives the GPU from `drm_device` and **forces** `gralloc.gbm.device` to match | a mismatch caused cross-GPU hand-off and 花屏 |
| §4g-bis | Makes vendor HALs resolvable | Android 13 black screen |
| §4f-bis | Shadows the audio HAL stub: copies the real `audio.primary.waydroid.so` over `audio.primary.default.so` | `ro.hardware.audio.primary` is unset, so the loader picked a 9800-byte stub and the system had **no audio at all** |
| §4g-ter | Restores the image's real `ro.build.type` | with `user`, SystemServer never registers `cmd`, so `am`/`cmd` fail with RC=255 and no output |
| §4h | libndk `MAP_32BIT` patch — **DISABLED, does not work** | kept as a documented dead end |
| §4i | Forces berberis interpret-only mode | fixed HoK code-pool exhaustion |
| §4i-bis | Forces Mesa to pick `radeonsi`, injects `DRI_PRIME` / `MESA_VK_DEVICE_SELECT` | black screen; also the only reliable way to get env into the guest (via the zygote rc) |
| §4i-ter | Gives hwcomposer a usable Wayland display (`/run/xdg`, `wayland-0`) | `Couldn't open Wayland display` → black screen |
| **§4j** | **Optional Houdini translator install, gated on `WAYDROID_ARM_TRANSLATOR=libhoudini`** | **fixes the periodic SIGSEGV — see §3** |
| §7 | Hands ownership to the session user | must run last |

Plus the rootfs unmount loop for stale mounts, and a **revert note** where
`ro.input.resampling=0` used to be (that experiment did not fix anything and was
removed — the comment records the negative result so it is not retried).

Rollback: delete the relevant section. **The two fixes this arc landed on are
§4d-bis (audio isolation) and §4j (translator switch)**; the sections covering
rendering, launch and the audio HAL were also written during this troubleshooting
work, and the rest were already in place. Removing any of them will re-break the
thing it fixed — the symptoms each one addresses are named in the table, so check
that column before deleting anything.

### 1.2 `overlay/etc/cont-init.d/20-waydroid-setup.sh` — the §4d-bis placement trap

Worth calling out because it cost a round: the hostname override **must live
outside** the `if [ ! -f "$WAYDROID_WORK/lxc/waydroid/config" ]` guard. That
guard only regenerates the LXC config when it is *missing*, and the config
persists on the data volume, so anything inside it never runs on a normal start.
The first attempt was inside and silently did nothing.

### 1.3 `scripts/waydroid-anrwait.sh`

| Change | Why |
| --- | --- |
| `_lxc()` uses `$_LXC`, not an undefined `$LXC` | the helper was a complete no-op; every command ran as `-- sh -c ...` and failed, with `2>/dev/null` hiding it |
| ANR "Wait" tap at 19% / 85% of the dialog frame | the old hardcoded 42%/106% landed on empty background |
| Parses the dialog's **own** frame from `dumpsys window windows` | the summary form's `mCurrentFocus` goes stale and made it tap the running game |
| Log-access dialog auto-tap **off by default** (`WAYDROID_LOGACCESS_AUTOTAP=1` to enable) | the dialog is a *symptom* of the game's crash, not a cause: it is created ~1.4 s **after** the SIGSEGV by the crash reporter reading logs. Tapping cannot save the game and injects input into the subsystem under investigation |

The ANR auto-wait itself is still on — it addresses a real startup problem.

### 1.4 `scripts/startup.sh`

| Change | Why |
| --- | --- |
| `RUN_SWAY` falsy normalization (`0`/`false`/empty all disable it) | the original `-n` test meant `RUN_SWAY=0` still enabled sway, which then died with `Could not connect to remote display` and took the container down |
| Kiosk block skipped when there is no compositor | no sway to configure |
| `hide_error_dialogs=0`, `policy_control=immersive.full=*` | crash/ANR dialogs should not cover the game |
| `READ_LOGS` pre-grant loop | **does not stop the log-access dialog.** Android 13 makes log access one-shot by design (issuetracker 243904932) and the permission is `prot=signature`. Kept only because it is harmless; the comment says so explicitly |

### 1.5 `waydroid-163/tools/helpers/mount.py`

Added `options.append("index=off")` to `mount_overlay()`.

* **Why it was added:** the overlay mount failed with `upperdir is in-use as
  upperdir/workdir of another mount`, Waydroid printed `Mounting overlays
  failed. The feature has been disabled.` and wrote `mount_overlays = False`.
  That removed the ARM translator from the guest, which broke the game's online
  mode (`libtprt.so` is AArch64 and `dlopen` failed).
* **Important caveat:** the kernel message was arguably *correct*. The most
  likely cause was a second container mounting the same upperdir, and
  `index=off` silences that protection rather than fixing it. Reverting it makes
  a second concurrent session **fail loudly** instead of sharing writable
  overlay state — which is safer, but that session loses the translator.
* Rollback: delete the appended option.

### 1.6 `Dockerfile`

| Change | Why |
| --- | --- |
| `COPY … --chmod=0777` → plain `COPY` + one `RUN chmod 0777` | `--chmod` is BuildKit-only; this removes one BuildKit dependency (the heredocs still need it) |
| `COPY houdini/libhoudini.zip /opt/gow/houdini/libhoudini.zip` | vendors the Houdini escape hatch; **inert unless `WAYDROID_ARM_TRANSLATOR=libhoudini`** |

### 1.7 `houdini/libhoudini.zip` (new, 75,152,963 bytes)

Intel Houdini ARM translator, Android 13 / WSA 11 build.

* md5 `37fe0899f1e4da7f9a724cca1c1ab1ea` — matches the value `waydroid_script`
  expects for the Android 13 archive
* source: `github.com/supremegamers/vendor_intel_proprietary_houdini`, commit
  `2f8f088671182e17e67321e098e8411a3972a628`
* rollback: delete the file and the `COPY` line in the Dockerfile. ~75 MB off
  the image.

### 1.8 `assets/wolf.config.toml`

`RUN_SWAY=false` on the Waydroid entry. **Template only** — the live config is
what matters (§2).

---

## 2. Runtime configuration changes (outside the repo)

These are not in the image and survive rebuilds.

### 2.1 Wolf's live config

Inside the `wolf` container: `/etc/wolf/cfg/config.toml`
(host path `/mnt/HGST4/wolf`). Both Waydroid entries, at lines **331**
(profile `moonlight-profile-id`) and **557** (profile `public`):

```toml
env = [ 'GOW_REQUIRED_DEVICES=/dev/input/event* /dev/dri/*',
        'WAYDROID_IMAGE_TYPE=VANILLA',
        'RUN_SWAY=false',
        'WAYDROID_ARM_TRANSLATOR=libhoudini' ]
```

* `RUN_SWAY=false` — there is no parent compositor; with sway on, the container
  exited 1 with `Could not connect to remote display`
* `WAYDROID_ARM_TRANSLATOR=libhoudini` — **this is what fixed the periodic
  in-game SIGSEGV**

Backups left in place:

```
/etc/wolf/cfg/config.toml.bak-20260918-235111   (before RUN_SWAY fix)
/etc/wolf/cfg/config.toml.bak-dri
/etc/wolf/cfg/config.toml.bak-houdini-140848    (before translator switch)
```

Rollback (then `docker restart wolf`):

```bash
# revert only the translator switch
docker exec wolf sed -i "s/, 'WAYDROID_ARM_TRANSLATOR=libhoudini'//" /etc/wolf/cfg/config.toml
docker restart wolf

# or restore wholesale
docker exec wolf cp /etc/wolf/cfg/config.toml.bak-houdini-140848 /etc/wolf/cfg/config.toml
docker restart wolf
```

### 2.2 `/data/waydroid/waydroid.cfg`

```
mount_overlays = True          # required, or the ARM translator never appears
drm_device = /dev/dri/renderD129
gralloc.gbm.device = renderD129
```

`renderD129` is the Renoir iGPU. Both values must agree; §4g now enforces that
from `drm_device`.

**Note:** Waydroid regenerates parts of its config at session start, so fixes
belong in the init script, not in hand edits here.

### 2.3 `/data/stacks/wolf/docker-compose.yml`

Added `WOLF_LOG_LEVEL=DEBUG` (line 12) for troubleshooting. There is no
`docker compose` binary on this host, so the stack is not managed from this file
in practice. Rollback: remove the line.

---

## 3. The two changes that actually fixed the reported problems

### 3.1 Periodic in-game SIGSEGV → Houdini (`§4j` + Wolf env)

**Symptom:** Honor of Kings died every ~4 minutes of play, always in
`libinput.so` `InputConsumer::hasPendingBatch` / `consumeSamples` at function
offset **+0**, seven tombstones, `Process uptime` 235–237 s.

**What was ruled out:** memory pressure (no cgroup limit, guest saw 24.5 GB
free, allocator steady at 60 MB), Java heap (`66% free, 10MB/31MB`), scudo heap
corruption (no allocator reports anywhere), the log-access dialog (created
*after* the crash), `ro.input.resampling` (tested and disproven), and my own
helpers (the crash reproduced with the auto-tap disabled and uptime 1434 s).

**Conclusion:** the game's anti-cheat (`libtersafe.so`/`libtprt.so` are loaded)
scans memory periodically during a match, and under Google's
`libndk_translation` that corrupts unrelated framework heap. Switching the ARM
translator to Intel Houdini removed the crash — **49 minutes continuous play,
and `dumpsys activity exit-info` shows no new exit** (the newest is still the
pre-switch one at 12:21:57).

This is the community's standard mitigation for this class of ARM-game crash
(waydroid#702, waydroid#1895). Note Houdini does not use libndk's EGL/GLES proxy
libraries, so rendering/audio/online were all re-checked afterwards.

### 3.2 Multi-device audio cross-talk → per-session hostname (`§4d-bis`)

**Symptom:** with two devices streaming, each heard the other's audio; later one
device had no sound at all.

**Root cause:** Wolf's pulse router attributes a stream to a session by the
PulseAudio client property `application.process.host`
(`src/moonlight-server/audio/pulse_router.cpp`), and its map is keyed by the
**container hostname**:

```
[PULSE_ROUTER] Map add host='01688ede1710' -> session='...'
```

libpulse fills that property from `gethostname()`, and Waydroid hardcodes
`lxc.uts.name = waydroid` for every container. So the lookup could never match —
measured on the live host, **31 `Map add` lines and 0 `Move sink-input` lines**,
i.e. routing had never once succeeded.

Nothing is captured from `auto_null` (the default sink), so an unrouted stream
gives silence; and whichever session's sink the stream lands on receives the
audio — which is how the same defect appeared as both cross-talk and silence.

**Fix:** §4d-bis sets `lxc.uts.name` to the container's own hostname, so the
property equals the map key. After the fix the router moved streams for the
first time, and every target index was cross-checked against the live
index→session assignment — all correct. Both sessions capture their own
monitor. User-confirmed working on two devices.

---

## 4. Known remaining hazards (deliberately not changed)

Both come from every Waydroid container binding the same `/data/waydroid`.

1. **Hostname race.** `/var/lib/waydroid/lxc/waydroid/config` is one shared file
   and each container writes its own `lxc.uts.name` into it. If one write lands
   before the other's `lxc-start`, that guest boots with the wrong hostname,
   both guests report the same host, and both sessions' audio routes to one
   side. Not observed in the sessions that could be inspected (the two guests
   had distinct hostnames), but the window is real.
   Fix if it bites: keep a per-container copy under `/run` and
   `mount --bind` it over the shared path before LXC starts.
2. **Shared overlay upperdir.** Two concurrent containers mount the same
   `overlay_rw/`, permitted only by the `index=off` in §1.5.
3. **Audio HAL crashes intermittently.** `android.hardware.audio.service` dies in
   `out_write` jumping to a wild pointer, correlated with session
   start/stop. Staged files were verified byte-identical to the image's
   originals, so this is Waydroid's own code, not the shadowing.

---

## 5. Verification commands

```bash
# which translator is live (expect libhoudini.so)
cid=$(docker ps -q --filter name=WolfWaydroid | head -1)
docker exec $cid lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- \
  sh -c 'getprop ro.dalvik.vm.native.bridge'

# init script ran the audio fixes
docker logs $cid 2>&1 | grep -E '\[audio\]|\[arm\]'

# per-session hostname == container hostname
docker exec $cid lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- \
  sh -c 'cat /proc/sys/kernel/hostname'
docker inspect $cid --format '{{.Config.Hostname}}'

# routing is actually happening (was 0 before the fix)
docker logs wolf 2>&1 | grep -a "Move sink-input" | tail

# no new game crash
docker exec $cid lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- \
  sh -c 'dumpsys activity exit-info com.tencent.tmgp.sgame | head -8'
```

Full investigation records, newest last:
`waydroid-hok-crash-round6.md`, `waydroid-hok-crash-round7.md`,
`waydroid-audio-isolation-fix.md`. Preserved evidence (3.5 MB logcat, tombstones,
ANR traces) is in `../diagnostics/hok-20260919/`.
