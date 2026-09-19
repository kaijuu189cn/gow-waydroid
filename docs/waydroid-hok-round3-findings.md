# Waydroid + Honor of Kings — round 3 findings (2026-09-19)

## Headline

**Honor of Kings runs.** It installs, launches, and reached its **full main
lobby with 3D character rendering** — verified by screenshot, game-log frame
counter 6940, and a 1.04 MB rendered frame (a black screen is ~4.7 KB).

Three real bugs were found and fixed this round, including one that had
silently disabled the ANR handler since it was written.

## Bugs found and fixed

### 1. The ANR helper was a total no-op (`$LXC` vs `_LXC`)

This is the most important find of the round.

```sh
_LXC="lxc-attach -P /var/lib/waydroid/lxc -n waydroid"
_lxc() { $LXC -- sh -c "$1" 2>/dev/null; }     # <-- $LXC, but the var is _LXC
```

`$LXC` is a **different, unset** name, so the function expanded to
`-- sh -c "..."`, failed instantly, and `2>/dev/null` swallowed the error.
`_info` was therefore always empty and the loop never tapped anything.

Proof, by tracing the two forms side by side inside the container:

```
A: direct  lxc-attach ... | grep -c "Application Not Responding"  -> 3
B: via var $LXC           ...                                     -> 0
C: via func _lxc          ...                                     -> 0
```

This is exactly why ANR dialogs piled up (8 at one point, 3 observed this
round) as if no helper were running at all. Fixed to `$_LXC`, and after the fix
the helper immediately started working:

```
[08:38:01] ANR dialog [224,154][1052,419] -> tap Wait (381,358)
[08:38:27] ANR dialog [224,154][1052,419] -> tap Wait (381,358)
```

and ANR windows dropped to **0**.

### 2. ANR tap coordinates were hardcoded for a different screen size

The fractions were 42% / 106% of the dialog frame, measured on a 1916x1053
display. On this 1276x637 panel the frame is `[224,154][1052,419]`, so 42%/106%
resolves to **(571,434)** — empty dialog background, not the "Wait" row. The tap
did nothing and the dialog never cleared.

Measured "Wait" row centre on this display is (380,357), i.e. **18.8% / 76.6%**.
Those fractions also land correctly on the larger screen, because the dialog
scales with the display:

| Display | Dialog frame | 19%/77% resolves to |
| --- | --- | --- |
| 1276x637 | [224,154][1052,419] | (381,358) — matches observed (380,357) |
| 1916x1053 | [527,380][1389,645] | (690,584) — Wait row |

The clamp was also hardcoded to 1916x1053; it now reads the real size via
`wm size`.

### 3. GPU pinning never reached Android

Section 4g writes `DRI_PRIME` / `MESA_VK_DEVICE_SELECT` into `lxc.environment`.
Verified on a live boot that this **does not reach Android**:

```
surfaceflinger    DRI_PRIME=0
composer@2.1-se   DRI_PRIME=0
```

Section 4i-bis now injects the same values through the **zygote rc overlay**,
the one mechanism proven to reach forked apps (the game process verifiably
carries `MESA_LOADER_DRIVER_OVERRIDE` and `GALLIUM_DRIVER` this way). The value
is derived from a new `WAYDROID_RENDER_NODE_RESOLVED` export in 4g, so the
renderer pin and `gralloc.gbm.device` cannot disagree.

Effect with all three pinned to one card:

| Renderer reported | GPU engine time | Outcome |
| --- | --- | --- |
| `gfx1200` (discrete) | 62 ms | 5 frames, black |
| `renoir` (iGPU) | **2.6 s** | reached the lobby |

A generic escape hatch was added for experiments without rebuilding:
`WAYDROID_MESA_EXTRA_ENV="VAR=value ..."`.

### 4. Dockerfile could no longer be built at all

The host's docker CLI is now 29.x, which has **no legacy builder and no buildx
component**, so every build failed:

```
--chmod option requires BuildKit        (default path)
BuildKit is enabled but the buildx component is missing or broken
```

The 10 `COPY --chmod=777` lines were replaced with plain `COPY` plus one
`RUN chmod 0777`. Identical result, works under both builders. The image now
builds again and the fixes are verified present inside it.

## Also established this round

* **The only reliable launch path** is the Waydroid session bus — `am`, `cmd`
  and `monkey` are all inert, and the launcher UI needs a working app-drawer
  gesture that a headless compositor does not deliver:

  ```bash
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/wolf/dbus-session-0
  waydroid app launch com.tencent.tmgp.sgame
  ```

* **A dead app leaves orphan processes that block relaunch.** After the game is
  killed, `xg_vip_service` and one orphan persist, so Android still thinks the
  app is running and `waydroid app launch` starts nothing new. Clearing them
  with SIGTERM (never SIGKILL — that wipes `/data/data`) restores launching.

* **A black screen does not always mean a crash.** Once the game was stuck at
  `Login_UI_Show` with a black frame, yet its network stack was healthy
  (`get msdk openid success`, TDM POST returning `error_code:0,
  error_msg:"OK"`). Game logic was running while rendering was stalled.

* **ANRs happen with no input at all.** In a 4-minute untouched run the log
  froze at frame 869 and 4 ANR dialogs appeared. So the ANR is not caused only
  by taps during loading — the main thread genuinely blocks past the 5001 ms
  input-dispatch timeout.

## Two-container conflict — my fault, and it matters

Your Moonlight session container started at **15:34**, while my test container
was also running. **Both bind `/data/waydroid`.** That is the same corruption
condition that has bitten this project before, and it is a plausible contributor
to the intermittent GL stalls I was chasing: two Androids sharing one userdata
volume.

Your container's own pipeline reached `End Of Stream` 31 s after starting
(`07:34:58`), so it had already ended before my cleanup. It is still up and
Android is healthy inside it (`sys.boot_completed=1`).

I also removed `wayland-2` from the shared runtime dir during cleanup, which was
the socket your container's mount pointed at. That socket was already dead, and
Wolf recreates the compositor and container on the next connect.

## Verified data integrity

```
/data/waydroid/userdata                       80G
/data/waydroid/userdata/data/com.tencent.tmgp.sgame   16G
Tencent packages installed                    4
```

No data loss. No test container left running; no stray wayland sockets.

## Remaining work

1. **The intermittent stall.** The game reached the lobby once but more often
   stops at the login UI with GL threads parked in `futex_do_wait` and
   `UnityMain` waiting on them. Notably this happened even when all DRM fds
   were on a **single** GPU (renderD129 only), so the cross-GPU split is not the
   whole story.
2. **Re-test without a second container running.** Given the shared-userdata
   conflict above, the stability results gathered this round are suspect. A
   clean run with only your session active is the right next measurement.
3. Confirm the new image works end-to-end through a real Moonlight connect.

## Image status

`gow-waydroid:latest` rebuilt successfully and verified to contain:
`$_LXC` fix, `_WAIT_FRAC_X=19/_WAIT_FRAC_Y=77`, GPU pin via zygote rc,
`WAYDROID_MESA_EXTRA_ENV` support, 0777 permissions.
