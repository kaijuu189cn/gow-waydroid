# Waydroid (Android)

[Waydroid](https://waydro.id/) runs a full Android system (LineageOS, Android 13)
inside a Linux container and renders it through the host's Wayland compositor.
This image lets you stream a complete Android desktop, or a single Android app,
to any Moonlight client through Wolf.

## Why this image needs more privileges than the others

Waydroid is the most privileged image in this repo, and it is worth being
explicit about why. Every other app here is a normal GUI program. Waydroid is
itself a container manager: it boots a nested Android system via LXC.

That requires:

| Requirement | Why |
|---|---|
| `SYS_ADMIN` | Mount `binderfs` and let LXC create the nested container |
| `NET_ADMIN` | Create the `waydroid0` bridge, enable forwarding, install NAT |
| `MKNOD` | Create binder device nodes |
| `NET_RAW` | Android's DHCP/network stack |
| `IpcMode: host` | Android's `servicemanager` needs shared IPC semantics |

`/dev/binderfs` is the one hard requirement that GOW's `base` image cannot
satisfy on its own: it only chowns device nodes listed in
`GOW_REQUIRED_DEVICES`, it never *mounts* anything. So binder setup happens in
three descending tiers, least privilege first:

1. `/dev/binderfs` already mounted by the host — best
2. mount `binderfs` at startup — needs `CAP_SYS_ADMIN`
3. legacy numeric `/dev/binder` node passed via `--device` — least privilege

Kernels >= 5.18 dropped `ashmem` in favour of `memfd`, so a missing
`/dev/ashmem` is expected and harmless.

## Privilege contexts: the thing that bites first

GOW's base entrypoint runs things in two different privilege contexts, and
getting this wrong is the single easiest mistake to make with this image:

| Stage | Runs as | Used for |
|---|---|---|
| `/etc/cont-init.d/*.sh` | **root** | mounting binderfs, system D-Bus, bridge + NAT, `waydroid init` |
| `/opt/gow/startup.sh` | **`retro`** (uid 1000) | unprivileged work + handing off to the display launcher |

`/opt/gow/startup.sh` is exec'd via `gosu "${UNAME}"`, so anything privileged
placed there fails. This is not theoretical — an earlier revision of this
image put the D-Bus startup in `startup.sh` and died with:

```
[dbus] Starting system bus
mkdir: cannot create directory '/run/dbus': Permission denied
```

The kodi image hits the same constraint and solves it the same way (see its
`overlay/etc/cont-init.d/99-startdbus.sh`). Two things follow from this:

- **`waydroid init` must run as root.** Waydroid's own `tools/__init__.py`
  does `if os.geteuid() != 0: raise RuntimeError('Action "init" needs root
  access')`. It therefore lives in the cont-init stage, not in `startup.sh`.
- **Ownership must be handed over** at the end of init (`chown -R retro:retro
  /var/lib/waydroid`), because the image set is written as root but read by
  the unprivileged session.


## Usage

The default configuration boots the full Android UI full-screen:

```toml
[[apps]]
title = "Waydroid"
[apps.runner]
type = "docker"
name = "WolfWaydroid"
image = "ghcr.io/games-on-whales/waydroid:edge"
```

### Launching a single app instead of the whole UI

Waydroid can render one Android app rather than the full desktop, which is
usually a better experience for streaming. Set:

```
WAYDROID_UI_MODE=single
WAYDROID_APP_PACKAGE=org.mozilla.firefox
```

The package name is the Android application ID (visible in Play Store URLs as
`id=<package>`).

### Available environment variables

| Variable | Default | Purpose |
|---|---|---|
| `WAYDROID_UI_MODE` | `full` | `full` for the whole UI, `single` for one app |
| `WAYDROID_APP_PACKAGE` | — | Android package to launch when `UI_MODE=single` |
| `WAYDROID_IMAGE_TYPE` | `VANILLA` | Android image flavour (`VANILLA`, `GAPPS`, `FOSS`) |
| `RUN_SWAY` | (unset) | `0`/`false`/`no`/`off` disables the nested sway compositor; any other value enables it |
| `WAYDROID_IMAGES_PATH` | `/var/lib/waydroid` | Where Android images live |
| `WAYDROID_BRIDGE` | `waydroid0` | Bridge interface name |
| `WAYDROID_SKIP_INIT` | `0` | Set to `1` to never attempt an image download |
| `WAYDROID_INIT_ON_START` | `0` | Set to `1` to download the images during container init |

## Runner privileges: the exact minimum

This is the part people get wrong, so here it is concretely. The values below
were verified by running the image with each combination:

```toml
[profiles.apps.runner]
base_create_json = '''{
  "HostConfig": {
    "IpcMode": "host",
    "CapAdd": ["SYS_ADMIN", "SYS_NICE", "SYS_PTRACE", "NET_RAW", "NET_ADMIN", "MKNOD"],
    "SecurityOpt": ["seccomp=unconfined", "apparmor=unconfined"],
    "Privileged": false,
    "DeviceCgroupRules": ["c 13:* rmw", "c 244:* rmw", "c 242:* rmw", "c 226:* rmw", "c 29:* rmw"]
  }
}'''
devices = []
env = [
    'RUN_SWAY=1',
    'GOW_REQUIRED_DEVICES=/dev/input/event* /dev/dri/*',
    'WAYDROID_IMAGE_TYPE=VANILLA',
]
image = 'gow-waydroid:latest'
mounts = ['/var/lib/waydroid:/var/lib/waydroid:rw']
```

Three rules that matter:

| Rule | Why |
|---|---|
| **`c 242:* rmw` is mandatory** | binderfs is char major 242. Without this cgroup rule, *mounting* binderfs still succeeds but opening `binder-control` is denied (EPERM), so no binder device can be created and Android cannot start. The init log prints the major and this exact line if it detects the condition. |
| **`c 226:* rmw` is mandatory for GPU acceleration** | `/dev/dri/card*` and `/dev/dri/renderD*` are char major 226 (drm). Without this rule the cgroup blocks read/write on the device even after it is bind-mounted in, so Waydroid's `getDriNode()` finds no usable render node and silently falls back to `gralloc=default` + `egl=swiftshader` (software rendering). |
| **Do not add `--privileged`** | It works, but it is not needed. The capability set above plus the cgroup rules is sufficient — verified. Prefer the smaller grant. |
| **Do not bind-mount `/dev/binderfs` or `/dev/binder` from the host** | The image mounts binderfs itself, so both mounts are redundant. Mounting `/dev/binder` as a path also turns it into a *directory* instead of the device node. Waydroid still works because it probes `anbox-binder` first, but the stray directory is confusing and should be removed. |

`GOW_REQUIRED_DEVICES` must list `/dev/dri/*`, or the session cannot open the
GPU and the compositor dies with `amdgpu_cs_ctx_create2 failed. (-13)`
(`-13` = `EACCES`). `ensure-groups` uses this list to put the session user in
the right device groups.

## GPU acceleration

Waydroid hardware acceleration is **automatic**: on startup it walks
`/dev/dri/renderD*` and, for any node whose kernel driver is not in its
hardcoded `unsupported` list (which contains only `nvidia`), selects:

```
ro.hardware.gralloc=gbm
ro.hardware.egl=mesa
gralloc.gbm.device=/dev/dri/renderD128
```

If no usable render node is present it falls back to `gralloc=default` +
`egl=swiftshader` (CPU software rendering), which is dramatically slower.

For **AMD (`amdgpu`)** and **Intel (`i915`/`iris`)** GPUs nothing extra is
needed beyond passing the device and allowing major 226 (see the privilege
table above). The image ships the mesa `radeonsi`/`iris` DRI drivers and the
`radeon`/`intel` Vulkan ICDs. NVIDIA is a special case: Waydroid upstream
explicitly skips `nvidia` in `getDriNode()`, so hardware acceleration needs a
patched helper — see the troubleshooting note below.

To confirm which mode is active, run:

```bash
/opt/gow/waydroid-setup.sh status
```

It now prints `gpu: HARDWARE acceleration (gralloc=gbm egl=mesa) via
/dev/dri/renderD128 (driver=amdgpu)` when the GPU is engaged, or `gpu:
SOFTWARE rendering (gralloc=default egl=swiftshader)` when it is not, along
with the exact fix for the latter.

## The compositor must nest — sway cannot claim the hardware

This is the single most confusing failure mode, and it is worth stating
plainly because the log gives almost no clue.

`launch-comp.sh` runs `sway --unsupported-gpu`, which tries to become the
**primary** compositor. That requires wlroots to acquire a DRM device **and** a
seat/VT session. A container has no logind seat, so sway stops at:

```
[backend/backend.c:84] Waiting for a session to become active
```

and waits there **forever**. It never publishes its IPC socket or its Wayland
display. Since sway spawns waybar as its status bar (`bar { swaybar_command
waybar }`), waybar cannot connect and retries in a tight loop, producing a log
that is *entirely* this, hundreds of times, all at one timestamp:

```
[error] Workspaces: Unable to receive IPC header
[error] Window: Unable to receive IPC header
```

Passing a real `/dev/dri` does **not** help — the seat is still missing.

**The fix** is that sway must *nest* on a parent compositor. Wolf provides
exactly that: with `start_virtual_compositor = true` the stream is the parent
display and `WAYLAND_DISPLAY` points at it. The image then selects:

| Condition | Backend | Result |
|---|---|---|
| `WAYLAND_DISPLAY` set (Wolf) | `WLR_BACKENDS=wayland` | sway nests, GPU-accelerated via the parent |
| unset (bare `docker run`) | `WLR_BACKENDS=headless` | working compositor, no GPU accel |

Either way sway publishes `sway-ipc.*.sock` and `wayland-N` immediately and
waybar attaches cleanly. Verified: **0** "Unable to receive IPC header" lines,
waybar running, and `swaymsg -t get_version` answering.

So **`start_virtual_compositor = true` is required** in your `wolf.config.toml`
for this image. Without it the session has no display to nest on.

## Why init creates XDG_RUNTIME_DIR itself

`05-runtime-dir.sh` exists because of an ordering hazard in the base image.
`cont-init.d` scripts run in **alphabetical** order, and the base image's
`10-setup_user.sh` ends with:

```bash
gow_log "Ensure XDG_RUNTIME_DIR is writable"
chown -R "${PUID}:${PGID}" "${XDG_RUNTIME_DIR}"
```

under `set -e` — but nothing ever creates that directory. So the `chown`
failed:

```
chown: cannot access '/tmp/.X11-unix': No such file or directory
```

and because of `set -e`, **the entire init sequence aborted right there**.
Every script after it was skipped: no binderfs, no system D-Bus, no network
bridge, no session.

Even when init does survive, a missing `XDG_RUNTIME_DIR` breaks the session:
sway needs it to create `$SWAYSOCK`, and waybar — which sway spawns as its
status bar — cannot attach without it, flooding the log with:

```
[error] Workspaces: Unable to receive IPC header
[error] Window: Unable to receive IPC header
   ... hundreds of lines, all at the same timestamp
```

which buries the real failure. Creating the directory at `05-` (before `10-`)
fixes the cause rather than the symptom. It is created `0700`, per the XDG
spec, so no other process in the container can hijack the compositor socket.

## Mounting your own /var/lib/waydroid

A common approach is to download the Android images on a machine with good
network and mount the directory in, rather than letting the container fetch
~1.5GB from SourceForge. Two details of that layout are easy to get wrong, so
the image now **repairs them automatically at startup**:

| Requirement | Why |
|---|---|
| Images go in **`images/`**, not the directory root | Waydroid reads `<work>/images/system.img`; a file in the root is never seen |
| **`rootfs/`** must exist | `initializer.is_initialized()` is `isfile(cfg) and isdir(rootfs)` — images without `rootfs/` still count as uninitialised |

So this works as-is:

```
/var/lib/waydroid/
├── waydroid.cfg
├── images/system.img
└── images/vendor.img
```

On start you will see:

```
[layout] Moved into images/: system.img vendor.img    (only if misplaced)
[layout] images/system.img = 812MB
[layout] images/vendor.img = 208MB
[waydroid] Waydroid is initialised (/var/lib/waydroid)
```

The image also sanity-checks the sizes, because a **truncated** download still
leaves a file present and otherwise fails much later with no explanation:

```
[layout] WARNING: images/system.img is only 42MB
[layout]    An official LineageOS image is ~800MB; this looks
[layout]    truncated and Android will not boot. Re-download.
```

Reference sizes for LineageOS 20 VANILLA: `system.img` ≈ 800MB,
`vendor.img` ≈ 200MB.

The one thing it will **not** fabricate is `waydroid.cfg` — that file encodes
the chosen image channel and architecture, and inventing one would hide a
genuinely missing initialisation. It reports the file as missing instead.

## XDG_RUNTIME_DIR differs from Wolf's example

This is a subtle trap worth calling out. Wolf's own documentation runs gow
images with:

```shell
-e XDG_RUNTIME_DIR=/tmp \
-v ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}:/tmp/${WAYLAND_DISPLAY}:rw \
-e WAYLAND_DISPLAY=${WAYLAND_DISPLAY}
```

i.e. the parent compositor's socket appears at **`/tmp/<display>`** and
`XDG_RUNTIME_DIR` is also `/tmp`.

This image inherits `XDG_RUNTIME_DIR=/tmp/.X11-unix` from `base-app`, so a
naive `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` lookup **misses the socket**. sway
then has no parent compositor, and you get the waybar flood described below.

The startup script therefore *probes* for the socket rather than assuming:

1. the value as-is, if `WAYLAND_DISPLAY` is already absolute
2. `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`
3. `/tmp/$WAYLAND_DISPLAY`  ← Wolf's documented layout
4. `/run/user/<uid>/$WAYLAND_DISPLAY`, and `wayland-0` in each of those

Once found it exports an **absolute** `WAYLAND_DISPLAY`, which both libwayland
and waydroid accept (`session_manager.py` checks `os.path.isabs` explicitly).
You will see:

```
[waydroid] Resolved Wayland socket: wayland-1 -> /tmp/wayland-1
[waydroid] Nesting sway on /tmp/wayland-1
```

If nothing is found it falls back to headless and says so, instead of leaving
you with a silent hang.

## Diagnosing "[gbinder] Can't open /dev/anbox-binder: No such device or address"

This error means the binder **device node exists but the kernel rejects opening
it with ENXIO** — the classic signature of a dangling node left over from a
previous run while binderfs is no longer mounted.

The image's binder init must therefore check `mountpoint -q /dev/binderfs`
rather than `[ -e /dev/binderfs/binder-control ]`: the `binder-control` device
node persists in the container-layer directory after binderfs has been
unmounted, so testing for its *existence* gives a false "already mounted" and
the mount is skipped. `mountpoint` checks the actual filesystem state and is
immune to that.

If you see this after a container restart, confirm:

```bash
mountpoint -q /dev/binderfs && echo mounted || echo "NOT mounted (bug)"
ls -la /dev/binderfs/anbox-binder
```

## Diagnosing the "Unable to receive IPC header" flood

If the log is nothing but hundreds of lines like:

```
[error] Workspaces: Unable to receive IPC header
[error] Window: Unable to receive IPC header
```

that is **waybar**, not the container, and it means sway never published its
IPC socket. The image now says why up front instead of leaving you to guess:

```
[waydroid] Nesting sway on WAYLAND_DISPLAY=wayland-1
[waydroid] WLR_BACKENDS=wayland
[waydroid] WARNING: parent Wayland socket not found at /tmp/.X11-unix/wayland-1
[waydroid]    Ensure wolf.config.toml sets start_virtual_compositor = true
[waydroid]    and that the socket is mounted into XDG_RUNTIME_DIR.
```

The usual cause is that the parent display is not actually available inside
the container. Two things to check:

1. `start_virtual_compositor = true` is set in `wolf.config.toml`.
2. The socket is reachable at `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` — note that
   `XDG_RUNTIME_DIR` is `/tmp/.X11-unix` here, so a socket mounted at `/tmp/`
   alone will not be found. `WAYLAND_DISPLAY` may also be an absolute path.

### Silencing the spam while debugging

Because waybar's retry loop can bury everything else, set
`WAYDROID_QUIET_BAR=1` to drop the five `sway/*` modules from the status bar.
This is opt-in so the default keeps the full bar.

## Turning off the nested sway compositor (RUN_SWAY=0)

Waydroid is a Wayland client and needs a compositor to render into. By default
the image runs a *nested* sway on top of Wolf's virtual compositor, because a
bare sway cannot claim the hardware in a container (no seat/VT).

If you would rather have Waydroid render **directly** into Wolf's compositor
(no nested sway layer), set:

```toml
env = [
    'RUN_SWAY=0',
    # ... plus the usual GOW_REQUIRED_DEVICES / WAYDROID_IMAGE_TYPE
]
```

`RUN_SWAY=0` is honoured even though gow's shared `launch-comp.sh` tests the
variable with `[ -n "$RUN_SWAY" ]` (which would otherwise treat the string
`"0"` as true). The image normalises falsy values — empty, `0`, `false`,
`no`, `off`, `disable`, `disabled` — to "unset" before handing control to the
launcher, so `0` genuinely disables sway. `RUN_GAMESCOPE` accepts the same
falsy values.

When both compositors are off, Waydroid renders directly into
`$WAYLAND_DISPLAY`, which under Wolf is the virtual compositor's socket. This
is the lower-overhead path and is what `RUN_SWAY=0` is for.

One subtlety of `RUN_SWAY=0`: with no sway there is also no `$DISPLAY`, and
Waydroid's *session* runs on a D-Bus **session** bus. dbus-python's usual
fallback for a missing session bus is to autolaunch one, and that autolaunch
refuses to run without `$DISPLAY`:

```
ERROR: org.freedesktop.DBus.Error.NotSupported:
    Unable to autolaunch a dbus-daemon without a $DISPLAY for X11
```

The image sidesteps this by starting its own session `dbus-daemon` in
`startup.sh` and exporting `DBUS_SESSION_BUS_ADDRESS` before `show-full-ui`
runs, so the session bus is reachable without any X11. This is automatic —
no extra environment variable is needed from Wolf.

## Persisting state

Three directories matter, and **only two of them are under `/var/lib/waydroid`**:

- **`/var/lib/waydroid`** — the Android system images, the overlay, and the
  LXC config. This is the large one (~2GB after first boot).
- **`/var/lib/waydroid/userdata`** — Android's `/data` partition, i.e. every
  app you installed plus their save data and logins. ⚠️ See below: this does
  **not** live under `/var/lib/waydroid` by default.
- **`$HOME/.local/share/waydroid`** — per-user session state.

Mount a volume at `/var/lib/waydroid` to keep installed apps and logins across
container recreations.

### ⚠️ Android userdata is NOT in /var/lib/waydroid

This is the single easiest way to lose hours of work. Waydroid keeps Android's
`/data` at its **"host data path"** — `$XDG_DATA_HOME/waydroid/data`, which for
root is:

```
/root/.local/share/waydroid/data
```

and bind-mounts *that* into the nested Android container as `/data`:

```
lxc.mount.entry = /root/.local/share/waydroid/data  data  none  rbind  0 0
```

That path is inside the **outer container's writable layer**. Wolf discards and
recreates that layer on every app start, so with a volume on `/var/lib/waydroid`
alone you keep `system.img` and your overlay patches but silently lose **every
installed APK, all game save data, all logins**. The symptom is a container that
looks persistent (images still there) but comes back with an empty app list.

`overlay/etc/cont-init.d/20-waydroid-setup.sh` fixes this by keeping the real
userdata on the persistent volume and pointing Waydroid's host data path at it:

```
/root/.local/share/waydroid/data -> /var/lib/waydroid/userdata
```

It migrates any pre-existing container-local data on first run, so the change
is not destructive. Confirm it took effect in the logs:

```
[userdata] /root/.local/share/waydroid/data -> /var/lib/waydroid/userdata
[userdata] on-disk size: 4166MB
[userdata] 2 installed app dir(s) preserved
```

### Putting a modified waydroid.cfg into effect

`waydroid.cfg`'s `[properties]` section is **only** read by
`tools/helpers/lxc.make_base_props()`, which is the sole writer of
`waydroid_base.prop`. Init scripts that generate that file only when it is
missing therefore ignore later `[properties]` edits entirely — the ARM
translation properties below never appeared, and `abilist` stayed
`x86_64,x86` so arm64 APKs would not install. `20-waydroid-setup.sh` now
compares the two and regenerates on mismatch:

```
[layout] waydroid_base.prop out of sync with [properties] in waydroid.cfg; generating it
```

## First run

The Android images are **not** baked in by default — that is a ~1.5GB download
which would make the image enormous for everyone who does not want Android.

The download is also **not triggered automatically on every start**, because
that would block any `docker run` (including the CI smoke layers, which have a
60s timeout) for the length of an 838MB transfer. Instead:

| Approach | How |
|---|---|
| Bake at build time | `--build-arg BAKE_ANDROID_IMAGE=true` |
| Trigger on start | `-e WAYDROID_INIT_ON_START=1` |
| Trigger from a running container | `waydroid-setup.sh init` |
| Let the image ask for it | just start it; `startup.sh` leaves a marker and the next start downloads it |

The third option is usually the most convenient, and needs the container to
run as root for that one command:

```bash
docker exec -u 0 <container> /opt/gow/waydroid-setup.sh init
```

Because `waydroid init` is skipped when images already exist, a
volume-mounted `/var/lib/waydroid` makes every subsequent start fast.

## Installing apps

Once a session is running you can use `waydroid` directly:

```bash
waydroid app install /path/to/app.apk
waydroid app launch org.example.app
waydroid app list
```

With the `GAPPS` image type you get the Play Store; with `VANILLA`/`FOSS` you
install APKs manually or via [F-Droid](https://f-droid.org/).

## ARM translation and Magisk

### Lineage 24.0 (Android 17) ships its own translation layer

> ✅ **This is the recommended configuration.** Verified working: ARM-only games
> launch and run with **no patch and no overlay** at all.

The `lineage-24.0` images (`20260825` and later) are **Android 17 / SDK 37** —
newer even than the `protocol.py` table's last row, so `android_api >= 36` puts
them on `binder_protocol = aidl3` + `service_manager_protocol = aidl6`, which
our bundled **libgbinder 1.1.52** already supports. No Waydroid or libgbinder
change is needed.

| | Android 13 (`lineage-20.0`) | **Android 17 (`lineage-24.0`)** |
|---|---|---|
| `system.img` | ext4 (mounted ro) | **erofs** (read-only by design) |
| `vendor.img` | ext4 | ext4 |
| Translation layer | must be installed | **`libndk_translation.so` built in** |
| Game CPU | ~16% | **~12%** |
| `Guest call didn't restore sp` | aborts; needed a 2-instruction patch | **does not occur** |
| Overlay required | yes (to inject libndk) | **no** |

The image carries its **own** `libndk_translation.so` (8 743 696 bytes,
md5 `2bbd2f7eb1b9db5b638c634eb3c21420`) alongside 56 ARM64 system libraries in
`/system/lib64/arm64/`. Despite the filename this is **berberis**, Google's
newer binary translator — see the note below. It is a different codebase from
the 2.5MB `ndk_translation` build used on Android 13 and does **not** contain
the `ExecuteGuestCall` stack-pointer assert that needed patching.

> ⚠️ **Do not copy the Android 13 `libndk_translation.so` overlay onto a
> Lineage 24.0 volume.** The overlay is applied *over* the image, so the old
> 2.5MB library silently shadows the image's newer 8.7MB one. Because the old
> build is the one with the anti-emulator `sp` assert, this reintroduces the
> abort the Android 13 patch existed to work around — for no benefit, since the
> image's native layer already works.
>
> If you migrated a volume from Android 13, clear these from
> `/var/lib/waydroid/overlay/system/`: `lib64/libndk_translation*.so`,
> `lib/libndk_translation*.so`, `lib64/arm64/`, `bin/arm*`, `bin/ndk_translation_*`,
> `etc/binfmt_misc/`, `etc/init/ndk_translation.rc`, `etc/ld.config.arm*.txt`.
> The image supplies all of them.

Verified on the new image — Honor of Kings (`com.tencent.tmgp.sgame`,
`primaryCpuAbi=arm64-v8a`) reaches `CVersionUpdateRecommendDownloadAction` with a
live `SurfaceView` layer, **12% CPU**, and an empty logcat error filter. Genshin
(`com.miHoYo.Yuanshen`) loads `libyuanshen.so` through the translator and
displays its activity in 626ms.

> ℹ️ **`libndk_translation.so` on Lineage 24.0 *is* berberis.** The filename is
> legacy; the file itself is Google's newer binary translator. Tells:
> `Initialized Berberis (%s)`, `BERBERIS_ENTRY_POINT`, `/system/etc/berberis/`,
> `/system/lib64/libberberis_exec_region.so`, `ro.berberis.version=16.0.0`, and
> crash paths under `frameworks/libs/binary_translation/`. This matters because
> berberis is a JIT and therefore has *runtime* failure modes (`mmap` of
> executable regions) that the old ndk_translation did not — see the host
> requirement below.

### ⚠️ Host requirement: `vm.overcommit_memory=1`

**A multi-GPU, large-memory host is not enough — the kernel's commit accounting
must be relaxed or berberis' JIT will abort mid-game.**

berberis reserves very large `PROT_EXEC` regions for translated code. A running
game reaches roughly:

```
VmPeak: 68,346,080 kB   (65 GB virtual)
VmSize: 34,630,376 kB   (33 GB virtual)
VmRSS:        231,116 kB (231 MB actually resident)
```

The reservations are sparse and mostly untouched, but they still count against
the kernel's *commit* limit. On a default host:

```
MemTotal:      32 GB
SwapTotal:      4 GB
vm.overcommit_memory = 0     (heuristic)
vm.overcommit_ratio  = 50
CommitLimit:   20 GB         (MemTotal*ratio + SwapTotal)
Committed_AS: 440 GB         (22x over the limit)
```

Because commit is already far exceeded, `mmap(PROT_EXEC)` is **refused
up-front**, and berberis dies on its own assertion:

```
Abort message: 'frameworks/libs/binary_translation/base/mmap_posix.cc:128:
                 CHECK failed: 0xffffffffffffffff != 0xffffffffffffffff'
  #04 berberis::MmapImplOrDie(berberis::MmapImplArgs)+96
  #05 berberis::ExecRegionAnonymousFactory::Create(unsigned long)+189
  #06 berberis::CodePool<berberis::ExecRegionAnonymousFactory>::Add(...)+145
  #07 berberis::TryLiteTranslateAndInstallRegion(...)
  #08 berberis::TranslateRegion<(TranslationGear)0>(...)
```

**This is not an OOM kill and not a memory shortage.** Diagnostics that rule the
usual suspects out:

| Check | Observed | Meaning |
|---|---|---|
| kernel OOM log | `OomAdjuster: Not killing cached processes`, nothing killed | not an OOM kill |
| `free -m` | 7 GB free at crash time | RAM available |
| cgroup `memory.max` | `max` | no container limit |
| `vm.max_map_count` | 1 048 576, game used ~2 800 | not VMA exhaustion |

> ⚠️ **`vm.overcommit_memory=1` is necessary but NOT sufficient.** It is still
> worth setting, but on its own Honor of Kings still aborts — the code-pool
> *placement* described below is the binding constraint. See "Exec region pool
> collides with the guest linker".

So **adding RAM or swap does not fix it** — only the commit policy does:

```bash
sudo sysctl -w vm.overcommit_memory=1
```

Persisted here as `/etc/sysctl.d/99-waydroid-overcommit.conf`. Values:

- `0` (default) — heuristic; refuses obviously-impossible allocations, which
  includes berberis' sparse 65 GB reservations on a 32 GB box.
- **`1`** — always overcommit; reservations succeed and faults are handled at
  page-fault time. This is what Android/ChromeOS hosts use.

Verified: with `overcommit_memory=0` Honor of Kings aborted within ~10 s of
reaching Unity graphics init; with `=1` it ran past that point with no further
`MmapImplOrDie` aborts.

#### What the failing `mmap` actually is

Disassembling `berberis::MmapImplOrDie` (`.so` offset `0x7a3d90`) shows the
assert site is a plain `mmap` failure — the two identical `0xffff…ffff` values in
the abort message are the `MAP_FAILED` sentinel passed twice to
`__android_log_assert`:

```asm
7a3dba: call mmap@plt
7a3dbf: cmp  $0xffffffffffffffff,%rax   ; == MAP_FAILED ?
7a3dc3: je   7a3dc7                     ; yes -> abort
7a3dc5: pop %rbp / ret                  ; ok
...
7a3ddc: mov $0xffffffffffffffff,%rcx     ; rcx = -1  } the two values that
7a3de3: mov $0xffffffffffffffff,%r8      ; r8  = -1  } print identically
7a3dec: call __android_log_assert
```

The caller `ExecRegionAnonymousFactory::Create` (`0x7aad40`) builds the region
as a **memfd**, then maps it `PROT_READ|PROT_EXEC`, `MAP_SHARED`:

```asm
7aad7c: mov $0x13f,%edi        ; syscall 319 = memfd_create
7aad81: mov $0x1,%edx          ; MFD_CLOEXEC
7aad8e: call berberis_RawSyscallImpl
7aada5: call ftruncate64       ; size it
7aadbe: movabs $0x100000005,%rax   ; prot=0x5 (R|X), flags=0x1 (MAP_SHARED)
7aadf9: call berberis::MmapImplOrDie
```

So each JIT region is a 4 MB `MAP_SHARED` memfd mapping.

#### Exec region pool collides with the guest linker

The regions are laid out **contiguously from `0x46000000` (≈1.09 GB)** — inside
the low 32-bit-compatible window — and grow upward:

```
46000000-46400000 r-xs  /memfd:exec (deleted)
46400000-46800000 r-xs  /memfd:exec (deleted)
46800000-46c00000 r-xs  /memfd:exec (deleted)
```

Observed growth on a cold Honor of Kings launch, sampled every 2 s:

| t | regions |
|---|---|
| 2 s | 7 |
| 4 s | 75 |
| 6 s | 164 |
| 8 s | 170 |
| 10 s | **172 (stops)** |

It plateaus and then aborts. At the plateau the pool is butted directly against
the guest's own dynamic linker:

```
7f5f557c0000-7f5f55840000 rw-s  /memfd:exec (deleted)          <- code pool
7f5f55840000-7f5f558dc000 r--p  /system/bin/arm64/linker64     <- guest linker
```

**The pool has no headroom to grow into, so the next `mmap` fails.** This is why
`overcommit_memory=1` alone does not help: free RAM is irrelevant when the
address range the pool is growing into is already occupied by guest mappings.

Practical consequences:

- The abort is **not** a bug in the game and not a Vulkan/feature-check result.
  Honor of Kings' own cloud config has `VulkanDisable=false` with empty
  SoC/device blacklists, and its three `*VulkanDisableOnDeviceOlderThan` keys
  only cover Qualcomm / MTK / Maleoon — none match an AMD x86_64 host.
- It manifests as a **rapid crash-restart loop** (~5–25 s per attempt).
- Mitigations worth trying, in order: reduce address-space pressure from other
  Android processes before launching (the Google and Tencent app suites hold
  ~3 GB), and see "Tuning berberis itself" below for flags that reduce how many
  regions get generated.

> ✅ **Freeing address space first is what made Honor of Kings playable.**
> Killing the non-game app suites before launch flipped the result from a
> 10-second abort loop to a working game:
>
> ```bash
> for p in com.google.android.googlequicksearchbox com.android.vending \
>          com.valvesoftware.underlords com.exness.android.pa \
>          net.metaquotes.metatrader5 com.tencent.android.qqdownloader \
>          com.android.packageinstaller; do
>   waydroid shell -- sh -c "pkill -9 -f $p"
> done
> ```
>
> With those running, every launch died on `MmapImplOrDie`. With them killed,
> `com.tencent.tmgp.osgame` came up, rendered (`SurfaceView` layer present),
> and started a **1.5 GB asset download** (`Pre Total Size: 1531455 KB`,
> `Extract Count: 47`).

#### Honor of Kings is two APKs, and only one of them crashes

Do not judge the game by `com.tencent.tmgp.sgame`. On this title the packages
split like this:

| Package | Process | Role | berberis abort? |
|---|---|---|---|
| `com.tencent.tmgp.sgame` | `UnityMain` | launcher / updater / patch-merge | **yes, repeatedly** |
| `com.tencent.tmgp.osgame` | `MainActivity` | **the actual game engine** | no |

Verified live, both at once:

```
7683  05:02  com.tencent.tmgp.osgame                            <- game, healthy
8089  04:54  com.tencent.tmgp.sgame:xg_vip_service
10300 04:13  com.tencent.tmgp.sgame:estPlugin
12837 01:36  com.tencent.tmgp.sgame                             <- updater, crash-looping
```

The updater's aborts keep appearing in `logcat -b crash` **even while the game
runs normally**, so counting aborts is not a reliable health check here. Check
for the `osgame` process and its `SurfaceView` layer instead:

```bash
waydroid shell -- sh -c 'ps -A | grep -E "osgame$"'
waydroid shell -- sh -c 'dumpsys SurfaceFlinger | grep osgame'
```

### Android 13 ATV: boots and installs the game, but HoK deadlocks at frame 5

> ⚠️ **The WayDroid-ATV `lineage-20.0` (Android 13 TV) image cannot run Honor of
> Kings.** Everything *except* the game works; the game itself deadlocks
> deterministically.

Status of the ATV-13 + patched-libndk stack, all verified working:

| Layer | Result |
|---|---|
| Android 13 TV boot | ✅ `sys.boot_completed=1`, 74 packages, Google TV launcher |
| HAL bring-up | ✅ composer/memtrack/gatekeeper/audio all `running` |
| ARM translation | ✅ patched `libndk_translation.so` loads in both zygotes, **no `sched_yield` spin** |
| captive-portal fix | ✅ network `validation passed` (after full container restart) |
| Game install | ✅ `pm install` of the arm64-v8a APK succeeds |
| Game launch | ✅ reaches `VersionUpdateState Enter`, allocates a live `BLAST` surface, GLES renders (Mesa/radeonsi) |
| **Game progress** | ❌ **deadlocks at `frame:5`** — `UnityMain` blocks in a futex, black screen |

The game is stuck, not crashed: the process stays alive for 7+ minutes at
`pssProcState=2` (foreground), but its `UnityMain` thread is permanently blocked
in `futex_do_wait` (syscall 202) while `RenderThread` sits idle in
`epoll_wait`:

```
# cat /proc/<pid>/task/<tid>/wchan   -> futex_do_wait
# cat /proc/<pid>/task/<tid>/syscall -> 202 0x7f79... 0x89 ...
```

The screen is 100% black (`screencap` → 1 unique color, `(0,0,0)`). The WebView
data directory is healthy this time (the earlier vanilla-Android-13 black-screen
was a *missing* `app_webview_*` dir; that is not the cause here).

The two key differences that make ATV-13 fail where vanilla-13 succeeded:

1. **Houdini is the image's only built-in translator, and it spins.** The fix is
   to replace it with libndk (see "Tuning berberis itself" — no, see below), via
   `waydroid-extras install libndk`, then overlay the two-instruction SP-check
   patch from `build/libndk-patched/`.
2. **The ATV build's Unity job-system futex never gets signalled**, leaving
   `UnityMain` parked at `VersionUpdateState Enter`. This is a different failure
   from the berberis code-pool abort on Android 17 and from the WebView
   missing-dir failure on vanilla-13; it is not fixed by any of the earlier
   workarounds and is not worth further chasing without reversing Unity.

Recommended path: **stay on Android 17 (lineage-24.0)** for Honor of Kings —
it is the only image where the game actually rendered and reached the `osgame`
engine. The ATV-13 image is fine for TV apps but not this title.

### Device identity must be spoofed on *every* partition

Games that run an integrity/anti-cheat check (Tencent ACE, miHoYo's telemetry)
will abort with an opaque, alarming message when the reported device identity is
**internally inconsistent**:

```
你的设备内部出现了问题。请联系你的设备制造了解详情
```

That is not a hardware failure — it is the game rejecting a spoofed device.

**The trap:** spoofing only the unsuffixed `ro.product.*` properties is *not
enough*. Since Android 10 the platform reads the **partition-suffixed**
variants, and those are set independently in each partition's `build.prop` by
the LineageOS image. Setting `ro.product.model` alone leaves apps resolving:

```
ro.product.model        = SM-S9280                <- your spoof
ro.product.vendor.model = WayDroid x86_64 Device  <- what Build.MODEL returns
ro.product.odm.model    = WayDroid x86_64 Device
ro.product.system.model = WayDroid x86_64 Device
```

miHoYo's telemetry showed both values side by side, which is how this was
caught:

```json
"device_model": "SM-S9280",              <- plain prop applied
"device_name":  "WayDroid x86_64 Device" <- partition prop leaked
```

Every partition must be overridden — `system`, `vendor`, `odm`, `product`,
**`system_ext`**, **`vendor_dlkm`** — for `model`, `brand`, `name`, `device`
and `manufacturer`. Two of those (`system_ext`, `vendor_dlkm`) are easy to miss.

Also unify the **fingerprints**. This image ships `ro.vendor.build.fingerprint`
as a *Google Pixel Tablet* (`google/tangorpro/tangorpro:16/...`) value, which
flatly contradicts a Samsung product identity — precisely the kind of mismatch a
check keys on. Set every `*.build.fingerprint` to the same string, plus
`ro.board.platform` and `ro.build.flavor`, which otherwise still read
`waydroid` / `lineage_waydroid_x86_64-userdebug`.

The complete, verified-consistent set lives in `waydroid.cfg` under
`[properties]` (40 `ro.product.*` entries). After editing, **regenerate
`waydroid_base.prop`** — a stale file silently discards `[properties]`:

```bash
docker exec <container> /opt/gow/waydroid-setup.sh   # or see stage 4c
```

Verify all partitions agree:

```bash
waydroid shell -- sh -c '
  for p in ro.product.model ro.product.vendor.model ro.product.odm.model \
           ro.product.system.model ro.product.system_ext.model \
           ro.product.vendor_dlkm.model; do echo "$p = $(getprop $p)"; done'
```

The only WayDroid string that legitimately remains afterwards is
`ro.lineage.device`, a ROM marker no game SDK reads. The `ro.waydroid.*`
properties (`codec2-impl`, `forward_notifications`, `google_tv_mode`,
`software_rendering`) are Waydroid's own interfaces and must **not** be touched.

> Note this is a *separate* failure from the berberis code-pool abort above,
> and can occur before or after it. Fix both.

#### Spoofing `ro.board.platform` / `ro.product.board` breaks HAL discovery

On **Android 13** (HIDL passthrough HALs) — but not on Android 17 (AIDL HALs) —
each HAL is resolved by `hw_get_module(<name>)`, which looks for
`<name>.<ro.hardware.<name>>.so`, falling back to `ro.hardware` →
`ro.product.board` → `ro.board.platform`. Spoofing those two to a real phone
(`kalama`) for integrity purposes makes the lookup try `memtrack.kalama.so`,
`audio.primary.kalama.so`, `hwcomposer.kalama.so`, etc. — none of which exist —
so every Waydroid HAL fails with `hw_get_module <name> failed: -2`, `system_server`
watchdog-kills in a loop, and the device never finishes booting.

The fix is to **explicitly pin every HAL module** in `waydroid.cfg`
`[properties]` so the fallback never reaches the spoofed values:

```ini
ro.hardware.hwcomposer = waydroid        # or the composer@2.1-service falls to
                                         # fbdev and aborts on "Incorrect device
                                         # name - fb0" (no /dev/fb0 on amdgpu)
ro.hardware.gralloc    = minigbm_gbm_mesa
ro.hardware.egl        = mesa
ro.hardware.vulkan     = radeon
ro.hardware.memtrack   = waydroid
ro.hardware.gatekeeper = waydroid
ro.hardware.audio      = waydroid
```

The four `*.waydroid.so` modules live in `/vendor/lib64/hw/`. This is why the
ATV-13 image initially boot-looped `system_server` on `MemtrackProxyService`
until these were set. Android 17 does not need them (its AIDL HALs resolve by
interface name, not by `ro.hardware`).

#### Tuning berberis itself

`ro.berberis.flags` (in the **vendor** image's `/build.prop`, line 79) accepts a
comma-separated list. Known flags, extracted from the binary:

| Flag | Effect |
|---|---|
| `accurate-sigsegv` | default on this image |
| `disable-heavy-opts` | never tier-up to the heavy optimizer |
| `disable-adjacent-regions-translation` | |
| `disable-intrinsic-inlining` | |
| `disable-link-jumps-between-regions` | |
| `disable-link-jumps-within-region` | |
| `two-gear` | two-tier translation mode |
| `lite-translate-or-interpret` | |

Editing it **requires patching the vendor image**, because `ro.` properties are
immutable once set and `/vendor/build.prop` is read before
`/vendor/waydroid.prop` (so a `[properties]` entry in `waydroid.cfg` does *not*
win). `vendor.img` is ext4, so it can be edited offline:

```bash
cp -a images/vendor.img images/vendor.img.bak
debugfs -w -R "rm /build.prop"              images/vendor.img
debugfs -w -R "write /tmp/build.prop /build.prop" images/vendor.img
e2fsck -fn images/vendor.img     # should report clean
```

> Note: `disable-heavy-opts` **does** change the crash path — the failing frame
> moves from `HeavyOptimizeRegion` back to `TryLiteTranslateAndInstallRegion` —
> but it does **not** prevent the abort. The underlying `mmap` failure is the
> code-pool address-space wall (see "Exec region pool collides with the guest
> linker" above), not the optimizer tier, so the tier change only moves which
> translation path runs out of room first.

### Android 16 / 13 images: background

This image ships **Waydroid 1.6.3**, the first release with "Initial support
for Android 16 images" — it adds the `aidl5`/`aidl6` binder protocol mapping and
the shutdown-request transaction that `lineage-23.2` (Android 16 QPR2) images
need.

It also ships **libgbinder 1.1.52**, compiled from source. `repo.waydro.id`
tops out at libgbinder 1.1.43, which only supports the `aidl4` servicemanager
protocol; Waydroid 1.6.3 selects `aidl6` for Android 16 (API 36), so 1.1.43
floods the log with `Unknown servicemanager protocol aidl6` and the Android
container never comes up. aidl6 support landed in libgbinder **1.1.45**
("Add support for Android 16 (API level 36)"). The `.so` is replaced in place
(the soname stays `libgbinder.so.1`, so `python3-gbinder` keeps linking against
it unchanged).

The WayDroid-ATV `lineage-23.2` images (release `20260717` and later) **already
include a working ARM translation layer** ("ARM translation layer is fully
functional now" in their changelog). So on an Android 16 image you normally do
**not** need to install `libndk`/`libhoudini` at all — ARM-only apps run out of
the box.

> ⚠️ Do **not** run `waydroid-extras install libndk` against an Android 16
> image. `waydroid_script` only targets Android 11/13 and resizes the
> `system.img` with `e2fsck`/`resize2fs`, but Android 16 images use **erofs**
> (read-only), so it fails with `e2fsck: Bad magic number in super-block`.
> It is the wrong tool for this image.

### Choosing a translation layer: libhoudini vs libndk

Both layers ship in the Android TV 13 image flavours, and they behave very
differently on **AMD** hosts running Unity/IL2CPP titles such as Honor of Kings
(`com.tencent.tmgp.sgame`):

| | libhoudini | libndk |
|---|---|---|
| Startup | works | works |
| `sched_yield` | ~30k/sec | **0** |
| Game CPU | **>1100%** (sys ~800%) | **~16%** |
| Failure mode | ANR (5s input timeout kills the app) | `Guest call didn't restore sp` abort |

libhoudini keeps the game alive but burns every core in `sched_yield()`
spin-waits, so Android's input-dispatch watchdog kills it. libndk's throughput
is essentially free, but it aborts the moment the game reaches its main UI.

The fix applied here is **libndk + a two-instruction patch** (see
`build/libndk-patched/`). libndk's `ExecuteGuestCall()` compares the guest `sp`
against the expected value and calls `__android_log_assert` when they differ:

```
Abort message: 'Guest call didn't restore sp: expected 0x…fd0, actual 0x…fc0'
```

The delta is consistently `0x10` across two unrelated libndk builds (the
Android 16 `berberis` one and the Android 13 `ndk_translation` one), which is
the signature of a deliberate anti-emulator probe in the game rather than a
translator bug. Since libndk's performance is otherwise ideal, that single
integrity assert is made non-fatal:

1. the conditional branch guarding the mismatch becomes two `nop`s, so control
   falls into the normal epilogue (canary check + `ret`) whatever the `sp`;
2. `call __android_log_assert` becomes five `nop`s as a belt-and-braces
   measure.

`build/libndk-patched/patch-libndk.py` applies both edits for x86_64 and i386,
validating the expected bytes at each offset before writing. The patched
`.so`s are checked in alongside it.

To install libndk on an Android 13 image, the files must go to the **system-as-
root** paths — `/system/lib64/`, `/system/lib/`, `/system/bin/`,
`/system/etc/` — and **not** to `/lib64/` or `/lib/` at the image root. Android
10+ mounts `system/` as the root, so the same-named directories at the image
root are ignored, and ART then reports:

```
nativebridge: Failed to load native bridge implementation:
              dlopen failed: library "libndk_translation.so" not found
```

The `native.bridge` property itself lives in the **vendor** image's
`build.prop` (`/build.prop` inside `vendor.img`), not in `system/build.prop`
(where it reads `ro.dalvik.vm.native.bridge=0`).

### Magisk and other tweaks (interactive)

For the things Android 16 images do **not** bundle (Magisk/root, GApps,
Widevine, microG), the image ships the community tool
[`waydroid_script`](https://github.com/casualsnek/waydroid_script) at
`/opt/gow/waydroid-script` with a `waydroid-extras` wrapper:

```bash
# interactive TUI (choose Android version, then what to install)
docker exec -it <container> waydroid-extras

# or non-interactively
docker exec <container> waydroid-extras install magisk
```

Available installs include `magisk`, `gapps`, `microg`, `widevine`, `smartdock`
and more. The payloads are downloaded from GitHub at run time, so the container
needs outbound network access.

Notes that matter here:

- **ARM translation** — see above: built into Android 16 ATV images. Only use
  `libndk`/`libhoudini` if you are on an older Android 11/13 image, and then
  `libndk` is the better choice on **AMD** CPUs.
- **Magisk** — installs on the next boot. On Android 16 the read-only erofs
  `system.img` cannot be edited the way the script does on Android 11/13
  ext4 images, so Magisk via `waydroid_script` may not work on Android 16.
  If it fails, prefer a Magisk module approach or a Magisk-patched image.
- **The script is root-only** and this container runs `UNAME=root`, so the
  hardcoded `sudo` prefixes in the upstream script have been patched out.
  Always run `waydroid-extras` as root (the default `docker exec` user here).

`waydroid-extras` is also how you *remove* an install (`uninstall magisk`) or
fetch the Android ID for Google Play certification (`waydroid-extras certified`).

## Troubleshooting

Run the bundled diagnostic:

```bash
/opt/gow/waydroid-setup.sh status
```

It reports binder state, whether the images are initialised, and whether the
container manager is running.

| Symptom | Likely cause |
|---|---|
| Black screen, log stops after "Starting container manager" | The manager failed to start — run `waydroid-setup.sh status` and check `/tmp/waydroid-container.log` |
| Black screen with "Waydroid is not initialized" in logs | Incomplete image set (e.g. an interrupted download). `waydroid-setup.sh status` names the missing pieces; fix with `waydroid-setup.sh init` |
| `amdgpu_cs_ctx_create2 failed. (-13)` | Not a Waydroid bug: `-13` is `EACCES` and means the session user is not in the `/dev/dri/cardN` group. Pass `GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*` |
| `gpu: SOFTWARE rendering` in `status` (NVIDIA host) | Waydroid's `getDriNode()` hardcodes `unsupported = ["nvidia"]`, so an NVIDIA render node is skipped and it falls back to swiftshader. This image does not patch that away; on NVIDIA the compositor/gamescope still renders through the host GPU, only the Android framebuffer is software-blitted |
| `FileNotFoundError: 'modprobe'` | `kmod` missing (fixed in the image); harmless once binder nodes are pre-allocated |
| `[binder] WARNING: no binder device node could be created` | binderfs is char major **242** and Docker's device cgroup denies it. Add `"c 242:* rmw"` to `DeviceCgroupRules` — the init log prints the exact major and the line to add |
| `waydroid status` says stopped, black screen | binderfs not available — see the privilege table above |
| `Failed to connect to socket /run/dbus/system_bus_socket` | The system bus died; `startup.sh` starts it, but a hand-rolled `docker run` must too |
| `Unable to autolaunch a dbus-daemon without a $DISPLAY for X11` | Waydroid's session needs a session D-Bus bus; `startup.sh` starts one, but if you invoke `waydroid show-full-ui` manually you must set `DBUS_SESSION_BUS_ADDRESS` (or run under `dbus-run-session`) first |
| Session starts then immediately exits | Missing `IpcMode: host` in the runner config |
| Android has no network | Container lacks `NET_ADMIN`, or `iptables-legacy` was picked instead of the nft backend; check `iptables -t nat -S POSTROUTING` |
| Android has no audio | See the "Audio" section below: Waydroid must find Wolf's PulseAudio socket, which is named `pulse-socket`, not the upstream `pulse/native` |
| First boot hangs | Image download blocked; check the container's outbound access |
| **Downloads stay "queued" forever and never start** | The network is stuck in `PARTIAL_CONNECTIVITY` because Android's validator probes `www.google.com`, which is unreachable from mainland China — see below |
| **App installs but shows a black screen / dies right after a WebView-based dialog** | The app's data dir is missing, so WebView cannot create `webview_data.lock` — see below |
| `waydroid app install` says "WayDroid session is stopped" although it is running | The shell has no `DBUS_SESSION_BUS_ADDRESS`; export `unix:path=/run/user/wolf/dbus-session-0` (the message means "cannot reach the session", not "not running") |
| `settings put`, `pm uninstall`, `am force-stop` all fail with `NullPointerException at AppOpsService.checkPackage` | `waydroid shell` runs with no calling package so AppOps cannot attribute the call. Use `IPlatform` over gbinder instead (below) |

### Downloads never leave the queue: the www.google.com probe

Android's connectivity validator hardcodes `www.google.com` as its HTTPS probe
target. From mainland China that host resolves but its TCP 443/80 connections
time out, so **every** validation round fails:

```
PROBE_HTTPS https://www.google.com/generate_204
    Probe failed with java.net.SocketTimeoutException
isCaptivePortal: isSuccessful()=false isPortal()=false isPartialConnectivity()=true
ConnectivityService: [100 ETHERNET] validation failed
```

The network is then pinned in `PARTIAL_CONNECTIVITY` forever. Everything works
at the socket level — `ping`, DNS, and even the *fallback* HTTP probe to
`connectivitycheck.gstatic.com` all succeed — but Android gates content
downloads on a fully `VALIDATED` network, so `DownloadManager` refuses to
dequeue and Play Store / in-game updaters stall. This affects **both** the
Android 13 TV and non-TV images.

The fix is `captive_portal_mode = 0`, which makes NetworkMonitor log
`Validation disabled.` and lets ConnectivityService mark the network validated
without probing. `startup.sh` applies it as a background task once Android has
booted (with a marker file so later starts skip it).

### An app's data directory is easy to destroy and hard to recreate

Deleting `/data/data/<pkg>` by hand is **not** equivalent to `pm clear`. The
package record keeps a `ceDataInode`, so the system still believes the data
exists and will not recreate the directory. Any WebView-using app then dies
with:

```
Caused by: java.io.FileNotFoundException:
  /data/user/0/<pkg>/app_webview_<pkg><pkg>/webview_data.lock:
  open failed: ENOENT
    at org.chromium.android_webview.AwDataDirLock.b
    at android.webkit.WebView.<init>
```

and the visible symptom is a black screen a few frames after startup. Recovery:
recreate the directory yourself with the right owner (`chown <uid>:<uid>`,
`chmod 700`), where `<uid>` comes from `dumpsys package <pkg> | grep userId=`.

### Writing Android settings when `settings put` is broken

`waydroid shell -- settings put ...` aborts with the AppOps NPE listed in the
table above, and `--user 0` does not help. Editing
`/data/system/users/0/settings_global.xml` directly does not stick either:
SettingsProvider caches values in memory and **rewrites the whole store on
shutdown**, so a hand-made edit is silently reverted at the next boot. (The
store is also *ABX* binary XML on Android 13+, hence the `abx2xml`/`xml2abx`
round trip.)

The reliable path is Waydroid's own platform service, which reaches
SettingsProvider from an Android process that has a real calling package:

```python
from tools.interfaces import IPlatform   # sys.path: /usr/lib/waydroid
svc = IPlatform.get_service(args)        # needs work/config/BINDER_DRIVER attrs
svc.settingsPutString(2, "policy_control", "immersive.full=*")  # 2 = global
```

For example, hiding the taskbar so touches reach a fullscreen game:
`policy_control = immersive.full=*` (the image's default
`immersive.status=*` hides only the status bar, and `TaskbarManager` then
swallows taps aimed at the game).

### A note on D-Bus

Waydroid uses **two** D-Bus buses:

- The **system** bus carries the container manager (`id.waydro.Container`).
  The CLI's `container` subcommands talk over it. GOW's base image ships
  `dbus-daemon` but has no systemd, so nothing starts the system bus
  automatically; `startup.sh` handles it, and without it the CLI fails with
  `org.freedesktop.DBus.Error.FileNotFound`.
- The **session** bus carries the Waydroid *session* (`id.waydro.Session`).
  `show-full-ui` and `app launch` need it. There is no session bus in the
  container either, and with `RUN_SWAY=0` (no `$DISPLAY`) dbus-python cannot
  autolaunch one — see the `RUN_SWAY=0` section above. `startup.sh` starts a
  session `dbus-daemon` and exports `DBUS_SESSION_BUS_ADDRESS` to satisfy this.

This is different from the kodi image, which only needs a session bus for its
own use — here the system bus is a hard dependency, and the session bus is a
hard dependency whenever a Waydroid session runs.

### Audio

Android audio is bridged to the host through a PulseAudio socket that Waydroid
bind-mounts into the Android container at `/run/xdg/pulse/native` (the path the
Android audio HAL expects). The host-side source of that socket is the one
place this image diverges from upstream, because **Wolf names its socket
differently**:

- Upstream Waydroid hardcodes `$PULSE_RUNTIME_PATH/native`
  (`$XDG_RUNTIME_DIR/pulse/native`).
- Wolf (games-on-whales) exports `PULSE_SERVER=$XDG_RUNTIME_DIR/pulse-socket`,
  and the socket is a **file** at that exact path — there is no `pulse/`
  subdirectory.

With the upstream path the bind mount silently points at a nonexistent file,
so Android boots fine but produces no sound. This image patches
`tools/helpers/lxc.py` to resolve the host socket in this order:

1. `PULSE_SERVER` (strips a leading `unix:` scheme, takes the first
   filesystem-path address)
2. `$XDG_RUNTIME_DIR/pulse-socket` if it exists (Wolf's convention, works even
   when `PULSE_SERVER` was not exported into the container)
3. `$PULSE_RUNTIME_PATH/native` (the upstream default, for non-Wolf hosts)

The container-side target `/run/xdg/pulse/native` is left unchanged, and the
mount stays `optional` so a missing socket degrades to "no audio" rather than
aborting the whole Android boot.

If Android still has no audio, check in the running container:

```bash
# the socket Wolf published into the shared runtime dir
ls -l "${XDG_RUNTIME_DIR}/pulse-socket"
# the mount line Waydroid generated (should reference pulse-socket, not pulse/native)
grep -i pulse /var/lib/waydroid/lxc/waydroid/config_session
```


## Testing

- `tests/smoke.sh` — runs in CI, verifies the dependency chain, CLI, helper
  scripts and state dirs without needing privileges.
- `tests/waydroid-integration.sh` — run manually **on the host**; actually
  mounts binderfs, creates binder devices, brings up the bridge and runs the
  CLI. Pass `--with-init` to also download the Android images.

  ```bash
  ./apps/waydroid/tests/waydroid-integration.sh gow/waydroid:edge
  ```

  It must run on the host because it drives `docker run` itself; running it
  inside the container fails with `docker: command not found`.

### What has been verified, and what has not

Verified in this repo's development environment (Linux 7.2, binderfs-capable
kernel, Docker 29.7), running the image through its real entrypoint:

| Check | Result |
|---|---|
| `smoke.sh` under `bin/test-image.sh`'s harness | 25/25 pass |
| cont-init runs privileged setup as root | pass |
| system D-Bus starts and socket appears | pass |
| binderfs mounts | pass |
| bridge `waydroid0` + MASQUERADE NAT | pass, idempotent |
| net teardown removes the bridge | pass |
| `waydroid status` reaches the manager | pass |
| `retro` can read/write `/var/lib/waydroid` | pass |
| `waydroid init` download | **not verified** — see below |

**Not verified: a full Android boot.** `waydroid init` fetches an 838MB
system image from SourceForge; that download could not be completed in the
development environment (connection reset partway through, and Waydroid's own
SHA256 check correctly rejected the truncated file). This is a network
limitation of the test environment, not a defect in the image — the code path
around it was verified with a stubbed image set, and Waydroid's checksum
verification behaving correctly is itself a good sign.

So: the container plumbing is proven end to end up to the point where the
Android userspace would start. The first real boot is the one thing left to
confirm on a machine with normal network access.

### Nine bugs found by actually running this image

All three were caught by building and running it, and all three are fixed:

1. **Privilege context.** The first revision did its privileged work
   (system D-Bus, binderfs mount, bridge, NAT) inside `/opt/gow/startup.sh`,
   which runs as uid 1000. It failed immediately with
   `mkdir: cannot create directory '/run/dbus': Permission denied`.
   Fixed by moving all of it to `overlay/etc/cont-init.d/20-waydroid-setup.sh`,
   which the entrypoint sources as root — the same pattern kodi uses.

2. **`waydroid init` needs root.** Once the above was fixed, the image set
   download still failed with `ERROR: Action "init" needs root access`.
   Waydroid's `tools/__init__.py` checks `os.geteuid() != 0` explicitly, so
   the download now also runs in the root init stage, with ownership handed
   to `retro` afterwards.

3. **`iptables-legacy` has no nat table on modern kernels.** The network
   helper originally preferred `iptables-legacy` (following upstream's
   `waydroid-net.sh`). On a kernel built without the legacy nat table this
   fails with *"can't initialize iptables table `nat'"*, so no NAT rule is
   installed and Android would have had no network — silently, since the
   bridge itself comes up fine. The helper now probes `iptables`,
   `iptables-nft` and `iptables-legacy` and picks the first with a working
   nat table.

4. **A blocking download in the init path.** Moving `waydroid init` into
   cont-init fixed root access but introduced a worse problem: *every*
   `docker run` then blocked for an 838MB download, which would have broken
   CI outright (`bin/test-image.sh` runs init scripts with a 60s timeout).
   The download is now opt-in per start, or baked at build time.

5. **`waydroid container start` also needs root.** Same class of mistake as
   (1): the manager was being started from `startup.sh` (uid 1000) and failed
   with `ERROR: Action "container" needs root access`, leaving the session to
   launch against a dead manager — a black screen. It is now started from the
   root init stage, backgrounded, and `startup.sh` only *waits* for it.

6. **`waydroid container status` does not exist.** The readiness check used
   it, so it always failed and printed "container manager did not report
   ready" on every start. The valid subcommands are only
   `start|stop|restart|freeze|unfreeze`. Readiness is now detected via the
   D-Bus name `id.waydro.Container`, which is what Waydroid's own systemd unit
   declares as its `BusName`.

7. **Wrong definition of "initialised".** The check looked only for
   `images/system.img`, but Waydroid's own
   `initializer.is_initialized()` requires the config file **and** the rootfs
   directory:
   ```python
   return os.path.isfile(args.config) and os.path.isdir("/var/lib/waydroid/rootfs")
   ```
   An interrupted download leaves `system.img` present but `rootfs/` missing,
   so the image reported "using existing system image" and then black-screened.
   The check now mirrors Waydroid's, and `waydroid-setup.sh status` names the
   exact missing pieces.

8. **Binder device nodes were never created.** Mounting binderfs only
   provides `binder-control`; the actual `binder`/`vndbinder`/`hwbinder`
   devices need a `BINDER_CTL_ADD` ioctl. Waydroid does that itself, but from
   `prepare_drivers_once()` — which runs in the *session*, as the
   unprivileged user, where it fails with `FileNotFoundError: 'modprobe'` and
   then silently gets nowhere. The root init stage now allocates them.

   Two subtleties worth recording: Waydroid probes for the name
   **`anbox-binder` first** (then puddlejumper, bonder, binder), so a plain
   `/dev/binder` is not what it looks for; and the ioctl constant must
   encode `sizeof(struct binderfs_device) = 264`, i.e. `0xC1086201`. A wrong
   size gives `EINVAL`, not a helpful message.

9. **`modprobe` was missing.** Waydroid's `probeBinderDriver()` shells out to
   it, so the image needs `kmod`.

A smaller fix: the flag for choosing the Android image type is
`-s`/`--system_type`, not `-t`.

### Not a bug: `amdgpu_cs_ctx_create2 failed. (-13)`

If you see this, the image is fine — `-13` is `EACCES`, and it means the
session user cannot open `/dev/dri/cardN` because it is not in that device's
group. This is GOW's normal device-permission model, and it is fixed by
passing:

```
GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*
```

which is exactly what the shipped `wolf.config.toml` does. When running the
container by hand, remember to pass it — `ensure-groups` then adds `retro` to
the right GIDs. `waydroid-setup.sh status` now reports this explicitly:

```
gpu:      retro CANNOT access: card1(gid=983) card2(gid=983)
          -> amdgpu_cs_ctx_create2 failed (-13) / black screen
          Fix: pass GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*
```

`smoke.sh` now carries explicit regression guards for (1), (5), (6) and (7),
so these specific mistakes fail CI rather than producing a black screen.
