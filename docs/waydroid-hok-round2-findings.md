# Waydroid + Honor of Kings — round 2 findings (2026-09-19)

## Summary

Android 13 boots and renders correctly in the Waydroid container, and Honor of
Kings **launches and stays alive** — but it never gets past its own startup
sequence. This round narrowed the cause precisely and tested five GPU
configurations. The remaining blocker is a **dual-GPU split inside Mesa**.

## What was verified working this round

| Check | Result |
| --- | --- |
| Android boot | `sys.boot_completed=1`, 92 processes |
| Display pipeline | `surfaceflinger` + `composer@2.1-se` running, VSync advancing |
| Compositor | `Compositor: none`, plain `exec` of waydroid-ui (no sway) |
| Screenshot | 1276x637 real launcher UI (clock, status bar, nav bar, dock) |
| HoK launch | `waydroid app launch` -> RC=0, focus on `SGameActivity`, 4 procs |
| HoK stability | Holds focus 90s+, no crash, no ANR, `/data/data` intact |
| Network | `ping 223.5.5.5` 7.7ms; 25 established `:443` connections |
| Tencent API | `GCloudCore OnDataTaskFinished error:0, httpStatus:200, 124ms` |
| GL driver | `libgallium_dri.so` loads, `MESA_LOADER_DRIVER_OVERRIDE=radeonsi` |

**The working HoK launch path** (replaces launcher-UI probing):

```bash
docker exec <cid> sh -c 'export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/wolf/dbus-session-0; \
  waydroid app launch com.tencent.tmgp.sgame'
```

`am`, `cmd` and `monkey` are all inert (RC=255, or silently no-op).

## The actual blocker: GL renders on a different GPU than gralloc

The game draws exactly **5 frames** and then stops. Thread evidence:

```
UnityMain (tid 2744)   futex_wait, syscall 202 (futex)
com.tencen:gl0 (2763)  libgallium_dri.so -> pthread_cond_wait -> cnd_wait
com.tenc:gdrv0 (2762)  same
com.tencen:sh0 (2755)  same
gl0 CPU time           utime=0 stime=1   <- never scheduled, zero CPU
gfxinfo                Total frames rendered: 5
SurfaceFlinger         LayerHistory{active=0}
```

The GL threads are parked inside Mesa's Gallium driver, and Unity's main thread
is waiting on them.

The reason is a GPU mismatch. This host has two AMD GPUs:

| DRM node | PCI ID | pdev | GPU | gfx level | Role |
| --- | --- | --- | --- | --- | --- |
| card1 / renderD128 | 1002:7590 | 0000:03:00.0 | RDNA4 discrete | **gfx1200** | GL renders here |
| card2 / renderD129 | 1002:1638 | 0000:06:00.0 | Renoir iGPU | gfx90c | gralloc allocates here |

Measured in the game process:

```
fdinfo/120 -> renderD128   drm-pdev 0000:03:00.0   drm-engine-gfx: 62244241 ns
fdinfo/172 -> renderD129   drm-pdev 0000:06:00.0   (no engine activity)
```

So the GL context lives on the discrete card while the display buffers are
allocated on the iGPU. Mesa reports `radeonsi, gfx1200` in `setGpuInfo`, and
`ShowVideo timeout` follows.

### Why the existing GPU pinning does not work

Section 4g writes `DRI_PRIME` / `MESA_VK_DEVICE_SELECT` via `lxc.environment`
in the LXC config. **That never reaches Android** — verified on a live boot:

```
surfaceflinger    DRI_PRIME=0
composer@2.1-se   DRI_PRIME=0
```

The root cause is upstream of env vars entirely:

```
MESA    : Using gralloc0 CrOS API
EGL-MAIN: failed to get driver name for fd -1
EGL-MAIN: MESA-LOADER: failed to retrieve device information
```

Mesa is handed **`fd -1`** — no DRM file descriptor. With no fd it cannot
enumerate devices, so `DRI_PRIME`, `MESA_device_select` and
`MESA_VK_DEVICE_SELECT` all have nothing to select between, and Mesa falls back
to its default device (gfx1200). `GALLIUM_DRIVER=radeonsi` only avoids the
"no driver at all" failure; it does not pin *which* radeonsi device.

## The fix that was implemented

Section 4i-bis now injects the GPU pin through the **zygote rc overlay** —
the same mechanism already proven to reach forked apps (the game process
verifiably carries `MESA_LOADER_DRIVER_OVERRIDE` and `GALLIUM_DRIVER` this way):

```
setenv MESA_LOADER_DRIVER_OVERRIDE radeonsi
setenv GALLIUM_DRIVER radeonsi
setenv DRI_PRIME pci-1002_1638
setenv MESA_VK_DEVICE_SELECT pci-1002_1638
```

The value is derived from `WAYDROID_RENDER_NODE_RESOLVED`, newly exported by
section 4g, so the renderer pin and `gralloc.gbm.device` can never disagree.
Verified in the live game process: `DRI_PRIME=pci-1002_1638` is present.

A generic escape hatch was also added: `WAYDROID_MESA_EXTRA_ENV="VAR=value ..."`
emits extra `setenv` lines, for testing without rebuilding the image.

**This did not by itself change the outcome** (`fd -1` means there is no device
list to select from), but it removes a real transmission bug and is a
prerequisite for any future pin to work.

## Configurations tested (all converge on gfx1200 + 5 frames)

| # | Configuration | Renderer | Frames |
| --- | --- | --- | --- |
| 1 | Default (`gralloc.gbm.device=renderD129`) | gfx1200 | 5 |
| 2 | + `DRI_PRIME=pci-1002_1638` in zygote rc | gfx1200 | 5 |
| 3 | + `MESA_device_select=pci-1002_1638` | gfx1200 | 5 |
| 4 | `WAYDROID_MULTI_GPU=keep` (no pinning at all) | gfx1200 | 5 |
| 5 | `WAYDROID_GRALLOC_DEVICE=renderD128` | gfx1200 | 5 |

Note for #5: the override was **ignored** — `getprop gralloc.gbm.device` still
returned `/dev/dri/renderD129`. That is a separate bug worth fixing.

## Correction to an earlier round's conclusion

I previously reported the stall as a network/resource error (`0x21300001`,
`556793857`) from the Sep 15 logs. That error is real but is a **downstream
symptom**: the game cannot render, so it never completes the update phase that
would request resources. This round's thread/fd evidence shows the rendering
stall happens first. Apollo initialisation is identical between "good" and
"bad" runs — the larger Sep 15 logs simply contained 4 app launches in one file,
which I initially misread as additional progress.

## Remaining work

1. **Give Mesa a real DRM fd.** The `fd -1` / `gralloc0 CrOS API` path is the
   root defect. Options: make the ARM64 EGL path use minigbm's fd, or hide the
   discrete card from Android's `/dev/dri` so Mesa's default is the iGPU.
2. **Fix `WAYDROID_GRALLOC_DEVICE` being ignored** on Android 13 — the log says
   `forced to renderD128` but the prop still reads renderD129.
3. Retest HoK once rendering is unblocked; the update/download phase has never
   actually been exercised to completion.

## Test harness notes

* `wolf-start-waydroid.py` had a hardcoded `RUN_SWAY=1` while claiming to read
  config.toml; it now fetches the runner from `GET /api/v1/apps`.
* Wolf tears its own compositor down within **87ms** when started headlessly via
  the API (no Moonlight client consumes the video), so the container dies with
  `OSError: container failed to start`. A standalone headless sway is the
  workaround: `WLR_BACKENDS=headless sway --unsupported-gpu`.
* Never `rm -f` a bind-mounted socket path — it turns `wayland-1` into a
  *directory* that permanently shadows Wolf's compositor socket. Use `rmdir`.
* The overlay rc is **regenerated from the pristine image on every container
  start**, so hand-edits to `/data/waydroid/overlay/...` are discarded. Fixes
  must go in the init script.
