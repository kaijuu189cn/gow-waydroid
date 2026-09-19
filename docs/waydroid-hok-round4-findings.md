# Waydroid + Honor of Kings — round 4 findings (2026-09-19)

## Headline

**One bug explained both reported problems.** The ARM64 translation overlay was
not mounted, so:
- the game's audio path (ARM64 `libaaudio.so`) could not load -> **no sound**
- the game's anti-cheat (`libtprt.so`, ARM64) could not load -> **online mode
  crashed**, while single-player (which does not need anti-cheat) worked

Fixed by adding `index=off` to Waydroid's overlay mount options.

## The chain, in full

### 1. Overlay mount failed

Waydroid mounts the guest root as an overlay so it can layer
`/var/lib/waydroid/overlay` (the ARM64 translator payload) over `system.img`:

```
mount -t overlay -o ro,lowerdir=/var/lib/waydroid/overlay:/var/lib/waydroid/rootfs,\
upperdir=/var/lib/waydroid/overlay_rw/system,\
workdir=/var/lib/waydroid/overlay_work/system,xino=off overlay /var/lib/waydroid/rootfs
```

That failed with:

```
mount: /var/lib/waydroid/rootfs: overlay already mounted on /.
```

and the kernel's real reason, from dmesg:

```
overlayfs: upperdir is in-use as upperdir/workdir of another mount,
          mount with '-o index=off' to override exclusive upperdir protection.
```

Overlayfs makes an upperdir exclusive to one mount. A Waydroid session that is
killed — or a streaming client that disconnects mid-boot — leaves its overlay
mounted in a namespace we can no longer reach or unmount, so the **next**
session's mount is refused.

### 2. Waydroid gave up permanently

Waydroid does not retry. It treats the failure as a kernel limitation and
switches the feature off for good:

```
Mounting overlays failed. The feature has been disabled.
Save config: /var/lib/waydroid/waydroid.cfg      <- mount_overlays = False
```

This is why the init script's own `mount_overlays = True` kept reverting: the
script sets it at cont-init, then Waydroid rewrites it to `False` when the
mount fails.

### 3. The translator disappeared

Verified inside the guest:

```
/system/lib64/libndk_translation.so                   MISSING
/system/lib64/libndk_translation_proxy_libaaudio.so   MISSING
/system/lib64/arm64/libaaudio.so                     MISSING
```

### 4. Both symptoms follow

Every ARM-only library is then handed to the x86_64 linker:

```
dlopen failed: ".../com.tencent.tmgp.sgame-.../lib/arm64/libtprt.so"
  is for EM_AARCH64 (183) instead of EM_X86_64 (62)
```

`libtprt.so` is Tencent's anti-cheat. Single-player never loads it, which is
exactly why single-player worked and online mode did not. The same missing
overlay removes the ARM64 audio runtime, so the game has no audio path at all.

## The fix

`tools/helpers/mount.py :: mount_overlay()` added `xino=off` but not
`index=off`. Added:

```python
    if kernel_version() >= versiontuple("4.17"):
        options.append("xino=off")

    # ... long comment explaining the container/stale-upperdir case ...
    options.append("index=off")
```

`index=off` is precisely what the kernel asks for, and the container's own root
overlay is mounted the same way. It lets the mount succeed even when a stale
holder of the same upperdir still exists.

Verified live before rebuilding:

```
mount -t overlay -o ro,...,xino=off,index=off overlay /var/lib/waydroid/rootfs
mounted?  YES
translator visible? /var/lib/waydroid/rootfs/system/lib64/libndk_translation.so
```

And after rebuilding, in a fresh container:

```
[overlay] mount_overlays = True (mount_overlays = True)
[overlay] /var/lib/waydroid/overlay: 183 file(s)
[overlay]    ok  system/lib64/libndk_translation.so
cfg: mount_overlays = True          <- now persists (was reverting to False)
```

## What is in the overlay (why this fixes audio too)

```
overlay/system/lib64/libndk_translation.so                    the translator
overlay/system/lib64/arm64/libaaudio.so                       ARM64 audio lib
overlay/system/lib64/libndk_translation_proxy_libaaudio.so    its proxy
overlay/system/lib64/arm64/libtprt.so                         anti-cheat
```

## Audio investigation findings (kept for reference)

Even with the overlay fixed, these are the facts gathered on the audio path:

| Check | Result |
| --- | --- |
| `init.svc.audioserver` / `vendor.audio-hal` | both running |
| `ro.hardware.audio` | `waydroid` |
| `audio.primary.waydroid.so` in vendor image | present, all deps satisfied |
| Guest `/run/xdg/pulse/native` | present, bind-mounted from Wolf's socket |
| LXC entry | `/run/user/wolf/pulse-socket run/xdg/pulse/native ... rbind,optional` |
| Wolf sink `virtual_sink_<session>` | created, but **IDLE with no sink-inputs** |
| HAL actually loaded | `audio.primary.**default**.so` (stub), not `.waydroid.so` |
| AudioFlinger | `getMicMute: error -38` (ENOSYS — classic stub-HAL signature) |

Two things were noted but are **not yet claimed as fixed**, because the overlay
fix was made afterwards and the audio path has not been re-tested since:

1. The HAL loading the `default` stub rather than the Waydroid module. The
   module exists and is configured as `<module name="primary" halVersion="2.0">`
   in `audio_policy_configuration.xml`, so it may be that the stub is simply
   what is loaded when no output is ever opened.
2. The relative mount target in the LXC config (`run/xdg/pulse/native` rather
   than an absolute path). The init script's own comment says relative targets
   fail, and it logs `Rewrote 3 relative LXC mount(s)`, yet the entries are
   still relative afterwards — Waydroid regenerates `config_session` after the
   rewrite. The write-up claims the mount is nonetheless working, which the
   live guest confirms, so this may be benign; it deserves a second look only
   if audio still fails.

**Retest audio after the overlay fix before changing anything else here** — the
missing ARM64 AAudio runtime is the most likely cause of no sound.

## Image and state

```
gow-waydroid:latest   index=off fix present, /usr/bin/waydroid present
waydroid.cfg          mount_overlays = True
                      drm_device = /dev/dri/renderD129
                      gralloc.gbm.device = renderD129     (consistent)
```

No test containers left running, no stray wayland sockets, 80 G game data
intact.

## Next steps

1. **Retest in Moonlight**: single-player audio, and online mode (the anti-cheat
   should now load).
2. If audio is still silent with the overlay working, revisit the HAL module
   selection (`default` vs `waydroid`) listed above.
3. If online mode still crashes, capture the new crash — with the translator
   present it would be a different, game-side cause.
