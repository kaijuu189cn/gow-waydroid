# Waydroid + Honor of Kings — session findings (2026-09-19)

## What now works

**Android 13 boots and renders correctly with NO sway.**

Verified end-to-end in a controlled container run:

```
sys.boot_completed            = 1
init.svc.surfaceflinger       = running
surfaceflinger (pid 108) + composer@2.1-se (pid 88)   both running
92 Android processes
screencap                     = 1276x637 PNG, 406KB, real launcher UI
```

A screenshot showed the full Android desktop: clock widget, status bar,
navigation bar, right-hand dock. The black-screen problem from earlier rounds
is **fixed**.

The compositor chain is correct:

```
[waydroid] Compositor: none (RUN_SWAY/RUN_GAMESCOPE off)
[waydroid]    Waydroid renders directly into $WAYLAND_DISPLAY.
[waydroid] Resolved Wayland socket: wayland-2 -> /run/user/wolf/wayland-2
[kiosk] no nested sway; skipping sway/waybar overrides
[exec] Starting: /usr/local/bin/waydroid-ui
```

## The HoK launch path that actually works

`am`, `cmd` and `monkey` are all inert on this image (RC=255 / no output).
The launcher UI works but is painful on this build — at 1276x637 the home
screen shows only a clock widget and a 4-icon dock, and the app-drawer swipe
does not register under a headless compositor.

**Use `waydroid app launch` over the Waydroid session bus instead.** It goes
through the IPlatform service rather than the dead `cmd` binder service:

```bash
docker exec <cid> sh -c 'export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/wolf/dbus-session-0; \
  waydroid app list; \
  waydroid app launch com.tencent.tmgp.sgame'
```

Result: `RC=0`, focus moved straight to
`com.tencent.tmgp.sgame/com.tencent.tmgp.sgame.SGameActivity`, 4 processes up.
This is far more reliable than probing launcher cells and should replace
`launch-app.sh` in future runs.

## Why the game is still black — game-side stall, not a display bug

After launching, HoK starts and **holds focus indefinitely with no crash and no
ANR** (4 processes stable for 90s+). But it renders nothing:

| Evidence | Value | Meaning |
| --- | --- | --- |
| `dumpsys gfxinfo` Total frames | **5** | game drew 5 frames then stopped |
| SF `VSyncState count` | 14574 -> 14818 | display pipeline is live and healthy |
| `LayerHistory{active=0}` | 0 active layers | nothing being submitted to compose |
| All game threads | `do_epoll_wait` / `futex_do_wait` | game is idle, waiting on I/O |
| `RenderThread` | `do_epoll_wait` | Unity render thread is NOT rendering |
| `dumpsys SurfaceFlinger` | buffers allocated, 1276x637, 3186KiB | memory is fine |

The game's own logs stop at exactly the same point every time:

```
[DLC] --jersay-- VersionUpdateState Enter
--zedd-- BeginRecord: VersionUpdateToLogin
--zedd-- BeginRecord: InitUnityService
--zedd-- EndRecord: InitUnityService        <-- LAST LINE
SGame_Activity: ShowVideo timeout           (logcat)
```

The log then freezes (8062 bytes, unchanged for 2.5+ minutes of monitoring).

This is the SAME failure identified in the previous round: the resource/version
update request is rejected and the game retries forever. The earlier evidence:

```
[CResourceDownLoaderOnStart.OnHanldeError]
OnResourceError error:556793857          (= 0x21300001)
CloudGame diskspace:146544MB             (not a disk-space problem)
[CBaseDownloader.DisposeRequest]         then retry ~3s later, loop
```

Network is NOT the blocker at this layer: from inside Android,
`ping 223.5.5.5` succeeds (7.7ms) and the game holds 25 established :443
connections. It reaches Tencent's servers and still gets the error back in
~60ms, which is far too fast for a timeout — a local/API-level rejection.

## Open question for the next round

The game's config carries `"DateStart": "20230627"` while the spoofed build
fingerprint is `TQ3A.230901.001` (Android 13, Samsung S24 Ultra). If
`0x21300001` persists on an unrestricted network, the fingerprint/version
spoof is the prime suspect — Tencent may be refusing to serve resources to a
device profile it considers inconsistent.

## Test-harness gotchas found this round

1. **`wolf-start-waydroid.py` was hardcoding `RUN_SWAY=1`** while claiming in a
   comment to read it from config.toml. Every "test" of the no-sway path was
   silently launching sway. Fixed: it now fetches the runner descriptor from
   `GET /api/v1/apps`, so it can never drift from the real config again.

2. **Wolf needs a real Wayland client to keep its compositor alive.** Started
   headlessly via the API, Wolf creates `waylanddisplaysrc` and then tears the
   whole pipeline down within **87ms** (`Pipeline reached End Of Stream`),
   because no Moonlight client is consuming video. The Waydroid container then
   dies with `OSError: container failed to start`. A standalone headless sway
   is the workaround used here.

3. **Never `rm -f` a bind-mounted socket path.** Doing so created a *directory*
   at `/data/stacks/wolf/run-user-wolf/wayland-1`, which then permanently
   shadowed Wolf's compositor socket and caused
   `WARNING: could not find Wayland socket for 'wayland-1'`. Use `rmdir` on the
   host path instead, and restart Wolf afterwards.

4. **`am`/`cmd`/`monkey` give no error when they fail** — `monkey` prints the
   parsed args and exits 0 while doing nothing. Never trust exit codes here;
   verify via `mCurrentFocus`.
