#!/bin/bash
# Privileged runtime setup for the Waydroid image.
#
# WHY THIS FILE EXISTS AND WHY IT IS NOT IN startup.sh
# ---------------------------------------------------
# GOW's base entrypoint runs things in two very different privilege contexts:
#
#   1. /etc/cont-init.d/*.sh  -- sourced as ROOT, before dropping privileges
#   2. /opt/gow/startup.sh    -- exec'd via `gosu ${UNAME}` as uid 1000
#
# Everything Waydroid needs at runtime is in category 1: mounting binderfs,
# starting the system D-Bus daemon, creating the waydroid0 bridge and
# installing iptables NAT rules. All of it requires root (plus the
# capabilities declared in assets/wolf.config.toml).
#
# This was originally written into startup.sh, which runs as `retro`, and
# failed at the very first step with:
#
#     mkdir: cannot create directory '/run/dbus': Permission denied
#
# The kodi image solves the same problem the same way (see its
# overlay/etc/cont-init.d/99-startdbus.sh), so this follows that precedent.
# startup.sh is left responsible only for unprivileged work and for handing
# control to the display launcher.
#
# This script must be idempotent: `docker restart` re-runs cont-init.d.
set -e

source /opt/gow/bash-lib/utils.sh

gow_log "**** Waydroid runtime setup (as $(id -un)) ****"

if [ "$(id -u)" != "0" ]; then
    gow_log "FATAL: this script must run as root; device/mount setup will fail"
    return 1
fi

#########################################
# 1. System D-Bus
#########################################
# Waydroid's CLI talks to its container manager over the *system* bus.
# GOW's base image ships dbus-daemon but has no systemd, so nothing starts
# it. Without this the CLI fails with:
#   org.freedesktop.DBus.Error.FileNotFound:
#     Failed to connect to socket /run/dbus/system_bus_socket
#
# Same approach as kodi: call dbus-daemon directly rather than
# `service dbus start`, because that only works on Ubuntu (Fedora 43 has no
# /usr/sbin/service).
if [ ! -S /run/dbus/system_bus_socket ]; then
    gow_log "[dbus] Starting system bus"
    mkdir -p /run/dbus
    dbus-daemon --system --fork --nopidfile
    for _ in $(seq 1 20); do
        [ -S /run/dbus/system_bus_socket ] && break
        sleep 0.5
    done
    if [ -S /run/dbus/system_bus_socket ]; then
        gow_log "[dbus] System bus up"
    else
        gow_log "[dbus] WARNING: system bus socket never appeared"
    fi
else
    gow_log "[dbus] System bus already running"
fi

#########################################
# 2. binder / ashmem
#########################################
# Android's userspace talks to the kernel over binder IPC. Old kernels
# exposed /dev/binder + /dev/ashmem as static nodes; modern kernels (5.x+)
# provide binderfs, which must be *mounted* before any binder device exists.
#
# GOW's base image only chowns/chmods already-existing nodes named in
# GOW_REQUIRED_DEVICES -- it never mounts anything. So we handle binder here,
# in three descending tiers of privilege:
#
#   1. /dev/binderfs already mounted by the host   (host prepared it)
#   2. mount binderfs now                          (needs CAP_SYS_ADMIN)
#   3. legacy numeric /dev/binder node             (passed via --device)
#
# Tier 3 matters because a Wolf runner can pass --device=/dev/binder without
# granting CAP_SYS_ADMIN at all, which is the least-privilege path.
#
# NOTE: the check must be `mountpoint -q`, NOT `[ -e /dev/binderfs/binder-control ]`.
# binder-control is a DEVICE NODE that persists on the host directory even after
# binderfs has been unmounted (e.g. across a container restart), so testing for
# its existence gives a false positive "already mounted" and the actual mount is
# skipped -- leaving a dangling device node that then fails to open with ENXIO:
#     [gbinder] ERROR: Can't open /dev/anbox-binder: No such device or address
if mountpoint -q /dev/binderfs 2>/dev/null; then
    gow_log "[binder] binderfs already mounted at /dev/binderfs"
elif [ -e /dev/binder ]; then
    gow_log "[binder] legacy /dev/binder device node present"
else
    gow_log "[binder] attempting to mount binderfs"
    mkdir -p /dev/binderfs
    if mount -t binder binder /dev/binderfs 2>/dev/null; then
        gow_log "[binder] binderfs mounted"
    else
        gow_log "[binder] WARNING: could not mount binderfs (needs CAP_SYS_ADMIN)"
        gow_log "[binder]    Pass --device=/dev/binder, or run with SYS_ADMIN."
    fi
fi

# Kernels >= 5.18 dropped the ashmem driver in favour of memfd, so a missing
# node is expected and not fatal.
if [ -e /dev/ashmem ]; then
    gow_log "[binder] /dev/ashmem present"
else
    gow_log "[binder] /dev/ashmem absent (expected on kernel >= 5.18, memfd)"
fi

#########################################
# 2d. Raise vm.max_map_count (gralloc OOM fix)
#########################################
# Waydroid's minigbm gralloc maps each buffer's metadata via
# mmap(MAP_SHARED, dmabuf_fd). Unlike anonymous mappings, MAP_SHARED file
# mappings are NOT merged by the kernel, so each buffer costs one VMA in the
# allocator@4.0 service process. Heavy 3D games (e.g. Honor of Kings via
# berberis) create millions of buffers, exhausting the default
# vm.max_map_count=1048576 and making the next mmap() return ENOMEM:
#     F/libc: mmap failed: Out of memory
#     -> allocator SIGABRT -> zygote cascade restart -> SYSTEM_RESTART
# Raising the limit to 10M VMAs fixes it. Requires CAP_SYS_ADMIN (privileged).
if [ -w /proc/sys/vm/max_map_count ]; then
    if [ "$(cat /proc/sys/vm/max_map_count 2>/dev/null)" -lt 10485760 ]; then
        echo 10485760 > /proc/sys/vm/max_map_count 2>/dev/null \
            && gow_log "[sysctl] vm.max_map_count raised to 10485760 (gralloc OOM fix)" \
            || gow_log "[sysctl] WARNING: could not raise vm.max_map_count"
    else
        gow_log "[sysctl] vm.max_map_count already >= 10485760"
    fi
else
    gow_log "[sysctl] WARNING: /proc/sys/vm/max_map_count not writable (needs CAP_SYS_ADMIN)"
fi

#########################################
# 2c. Pre-create loop device nodes
#########################################
# system.img is an erofs *file*, so `mount -o ro system.img rootfs` needs a
# loop device (major 7) to back it. The Wolf runner's /dev is a bare tmpfs
# (it only passes the devices named in GOW_REQUIRED_DEVICES), so /dev/loop0
# and /dev/loop-control are absent and the mount fails with:
#     mount: ... failed to setup loop device for .../system.img.
# We have CAP_MKNOD here (cont-init runs as root before privilege drop), so
# create the nodes ourselves. loop-control lets the kernel pick a free loop;
# a handful of loopN nodes let older tooling open one directly.
if [ ! -e /dev/loop-control ]; then
    mknod /dev/loop-control c 10 237 2>/dev/null \
        && gow_log "[loop] created /dev/loop-control" \
        || gow_log "[loop] WARNING: could not create /dev/loop-control"
fi
if [ ! -e /dev/loop0 ]; then
    mknod /dev/loop0 b 7 0 2>/dev/null \
        && gow_log "[loop] created /dev/loop0" \
        || gow_log "[loop] WARNING: could not create /dev/loop0"
fi
# A few more loop nodes for robustness (multiple images mounted at once).
for _n in 1 2 3 4 5 6 7; do
    [ -e "/dev/loop${_n}" ] || mknod "/dev/loop${_n}" b 7 "$_n" 2>/dev/null || true
done

#########################################
# 2b. Pre-allocate binder device nodes
#########################################
# Mounting binderfs only creates binder-control; the actual binder devices
# appear when someone opens binder-control with BINDER_CTL_ADD. Waydroid does
# that itself in container_manager.prepare_drivers_once() -- but that runs in
# the SESSION, as the unprivileged user, and creating device nodes needs
# CAP_MKNOD plus a writable /dev. So the nodes must be made here first.
#
# Naming matters: Waydroid tries BINDER_DRIVERS in order and the first entry
# is "anbox-binder" (then puddlejumper, bonder, binder), so a plain
# /dev/binder is NOT what it looks for. We create all three families under
# every name it might pick, which is cheap and makes the session's probe
# succeed regardless of which alias it settles on.
#
# Waydroid also expects to find them simply *present*; probeBinderDriver()
# only shells out to `modprobe` when none of the names exist.
if mountpoint -q /dev/binderfs 2>/dev/null; then
    gow_log "[binder] Allocating binder device nodes"

    # Ask the kernel to create the devices via binderfs, using the same
    # ioctl Waydroid would use: BINDER_CTL_ADD = _IOWR('b', 1, struct
    # binderfs_device{char name[256]; __u32 major; __u32 minor;}), which is
    # sizeof=264 -> 0xC1086201. Getting this constant wrong yields EINVAL,
    # not a clear error, so it is spelled out here.
    if python3 - <<'PYEOF' 2>/dev/null
import fcntl, os, struct
BINDER_CTL_ADD = 0xC1086201
for name in ("anbox-binder", "anbox-vndbinder", "anbox-hwbinder",
             "binder", "vndbinder", "hwbinder"):
    try:
        fd = os.open("/dev/binderfs/binder-control", os.O_RDONLY)
        buf = name.encode() + b"\x00" * (256 - len(name)) + struct.pack("II", 0, 0)
        fcntl.ioctl(fd, BINDER_CTL_ADD, buf)
        os.close(fd)
    except Exception:
        # Already exists (EEXIST) or the kernel rejected it; either way the
        # symlink step below will handle whatever did get created.
        pass
PYEOF
    then
        # Expose them at the canonical /dev/ paths Waydroid checks.
        for dev in /dev/binderfs/*; do
            base="$(basename "$dev")"
            case "$base" in
                binder-control|features) continue ;;
            esac
            [ -e "/dev/$base" ] || ln -sf "$dev" "/dev/$base" 2>/dev/null || true
        done
        chmod 666 /dev/binderfs/* 2>/dev/null || true

        # ------------------------------------------------------------------
        # CRITICAL: /dev/binder must resolve to the SAME binder device that
        # Android's servicemanager is bound to.
        # ------------------------------------------------------------------
        # LXC mounts the *anbox-binder* family into Android:
        #
        #     lxc.mount.entry = /dev/anbox-binder ... /dev/binder
        #
        # so Android's servicemanager binds device 242:1:
        #
        #     $ ls -la /proc/31/fd | grep binder      # 31 = servicemanager
        #     3 -> /dev/binder                        # inside Android, 242:1
        #
        # But on the CONTAINER side, /dev/binder is a symlink to
        # /dev/binderfs/binder -- a DIFFERENT device (242:4):
        #
        #     /dev/binder        -> /dev/binderfs/binder       242,4
        #     /dev/anbox-binder  -> /dev/binderfs/anbox-binder 242,1
        #
        # Waydroid's session-side Python client (IPlatform.get_service) opens
        # "/dev/" + args.BINDER_DRIVER and then asks *that* device for the
        # service manager. Pointed at 242:4 it finds nothing and hangs forever
        # printing:
        #
        #     [waydroid app launch ...] Waiting for binder Service Manager...
        #
        # which is exactly the symptom we chased: Android boots fine, `lxc-attach
        # -- am start` works (it goes through Android's own 242:1), but every
        # session-mediated command (app launch, show-full-ui) stalls, and
        # `waydroid status` reports Session: STOPPED.
        #
        # Repoint the canonical names at the anbox-* nodes so the container's
        # view matches Android's. Only replace symlinks we own; never clobber a
        # real device node that Docker passed in.
        for pair in "binder:anbox-binder" \
                    "vndbinder:anbox-vndbinder" \
                    "hwbinder:anbox-hwbinder"; do
            want="${pair%%:*}"
            src="${pair##*:}"
            if [ -c "/dev/binderfs/$src" ]; then
                if [ -L "/dev/$want" ]; then
                    ln -sfn "/dev/binderfs/$src" "/dev/$want" 2>/dev/null || true
                elif [ ! -e "/dev/$want" ]; then
                    ln -sfn "/dev/binderfs/$src" "/dev/$want" 2>/dev/null || true
                fi
            fi
        done

        # Report the mapping so a future mismatch is obvious in the log.
        for want in binder vndbinder hwbinder; do
            if [ -e "/dev/$want" ]; then
                gow_log "[binder] /dev/$want -> $(readlink -f "/dev/$want" 2>/dev/null)" \
                        "($(stat -Lc '%t:%T' "/dev/$want" 2>/dev/null))"
            fi
        done
    fi

    # Do not fail the boot over this: if the nodes are missing the session
    # will report it, and we would rather come up and be diagnosable.
    if [ -c /dev/anbox-binder ] || [ -c /dev/binder ]; then
        gow_log "[binder] Device nodes ready"
    else
        gow_log "[binder] WARNING: no binder device node could be created"
        # The overwhelmingly common cause is the device cgroup, not the
        # kernel: binderfs lives on char major 242, and Docker's default
        # device cgroup denies opening binder-control unless a matching
        # DeviceCgroupRules entry exists. Without it, root's open() fails
        # with EPERM and the ioctl can never run -- while the binderfs mount
        # itself succeeds, which makes the failure look mysterious.
        binder_major="$(stat -c '%t' /dev/binderfs/binder-control 2>/dev/null || echo '?')"
        gow_log "[binder]    binderfs char major is 0x${binder_major} ($((16#${binder_major:-0})) decimal)"
        gow_log "[binder]    Add this to the runner config and restart:"
        gow_log "[binder]      \"DeviceCgroupRules\": [\"c $((16#${binder_major:-0})):* rmw\"]"
        if ! python3 -c 'open("/dev/binderfs/binder-control")' 2>/dev/null; then
            gow_log "[binder]    Confirmed: opening binder-control is denied (device cgroup)"
        fi
    fi
else
    gow_log "[binder] No binderfs; cannot allocate device nodes"
fi

#########################################
# 3. Networking
#########################################
# Android expects a real NIC, so Waydroid builds its own bridge + NAT.
# Needs NET_ADMIN. Failure here is not fatal for the container itself but
# does mean Android has no outbound connectivity, so we report it clearly
# rather than aborting the boot.
if [ -x /opt/gow/waydroid-net.sh ]; then
    if /opt/gow/waydroid-net.sh start; then
        gow_log "[net] Bridge ready"
    else
        gow_log "[net] WARNING: network setup failed; Android will have no network"
    fi
fi

#########################################
# 4. State directories
#########################################
# Waydroid writes its images and LXC config under /var/lib/waydroid and its
# runtime sockets under /run/waydroid-lxc.
mkdir -p /var/lib/waydroid /var/lib/waydroid/lxc /run/waydroid-lxc

# XDG_RUNTIME_DIR is handled by 05-runtime-dir.sh, which must run before the
# base image's 10-setup_user.sh chowns it (see that script for the full story:
# a missing runtime dir makes 10-setup_user.sh abort the entire init sequence
# under `set -e`). Nothing to do here, but assert it survived so a later
# failure is attributed correctly.
if [ ! -d "${XDG_RUNTIME_DIR:-/tmp/.X11-unix}" ]; then
    gow_log "[runtime] WARNING: XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} missing;"
    gow_log "[runtime]    sway's IPC socket cannot be created (05-runtime-dir.sh failed)."
fi

#########################################
# 4b. Repair the /var/lib/waydroid layout
#########################################
# Users routinely mount a host directory at /var/lib/waydroid and drop the
# images in by hand. Two things about that layout are easy to get wrong, and
# both produce a confusing "not initialized" with no useful error:
#
#   a) The images must be in an `images/` SUBDIRECTORY. Waydroid reads
#      config.defaults["images_path"] == "<work>/images", so a system.img
#      sitting in the work root is simply never seen, and Waydroid will
#      re-download or report uninitialised.
#
#   b) `rootfs/` must exist. initializer.is_initialized() is literally
#          os.path.isfile(cfg) and os.path.isdir("/var/lib/waydroid/rootfs")
#      so images present but no rootfs/ still counts as NOT initialised.
#      (Note rootfs is a hardcoded default, not derived from images_path.)
#
# Both are safe to fix automatically: moving an image into images/ only
# happens when it is not already there, and mkdir is idempotent. Doing this
# here means a hand-populated volume just works instead of needing the user
# to read Waydroid's source.
#
# Deliberately does NOT fabricate waydroid.cfg: that file encodes the chosen
# image channel and arch, and inventing one would mask a genuinely missing
# init. Missing cfg is reported instead.
_layout_repair() {
    local work="$1"
    [ -d "$work" ] || return 0

    mkdir -p "${work}/images" 2>/dev/null || true

    local moved=""
    for img in system.img vendor.img; do
        if [ -f "${work}/${img}" ] && [ ! -f "${work}/images/${img}" ]; then
            if mv "${work}/${img}" "${work}/images/${img}" 2>/dev/null; then
                moved="${moved} ${img}"
            fi
        fi
    done
    [ -n "$moved" ] && gow_log "[layout] Moved into images/:${moved}"

    # rootfs/ + the overlay dirs waydroid init would otherwise create.
    mkdir -p "${work}/rootfs" "${work}/overlay/vendor" \
             "${work}/overlay_rw/system" "${work}/overlay_rw/vendor" 2>/dev/null || true

    # Report what we see, so a truncated download is obvious rather than
    # surfacing later as an unbootable Android with no explanation.
    if [ -f "${work}/images/system.img" ]; then
        local sz
        sz=$(stat -c%s "${work}/images/system.img" 2>/dev/null || echo 0)
        # Official LineageOS 20 VANILLA system.img is ~800MB. Anything under
        # 100MB is certainly a truncated download.
        if [ "$sz" -lt 104857600 ]; then
            gow_log "[layout] WARNING: images/system.img is only $((sz/1048576))MB"
            gow_log "[layout]    An official LineageOS image is ~800MB; this looks"
            gow_log "[layout]    truncated and Android will not boot. Re-download."
        else
            gow_log "[layout] images/system.img = $((sz/1048576))MB"
        fi
    fi
    if [ -f "${work}/images/vendor.img" ]; then
        local vsz
        vsz=$(stat -c%s "${work}/images/vendor.img" 2>/dev/null || echo 0)
        gow_log "[layout] images/vendor.img = $((vsz/1048576))MB"
    fi

    if [ ! -f "${work}/waydroid.cfg" ]; then
        gow_log "[layout] WARNING: waydroid.cfg missing; Waydroid will report"
        gow_log "[layout]    'not initialized' even with valid images present."
    fi
}

WAYDROID_WORK="${WAYDROID_WORK:-/var/lib/waydroid}"
_layout_repair "$WAYDROID_WORK"

#########################################
# 4b-2. Persist Android userdata
#########################################
# Android's /data partition is NOT under /var/lib/waydroid. Waydroid stores
# it at its "host data path" -- $XDG_DATA_HOME/waydroid/data, which for root
# (this image runs UNAME=root) is:
#
#     /root/.local/share/waydroid/data
#
# and bind-mounts that directory into the nested Android container as /data
# (the generated lxc/waydroid/config_session contains the matching
# `lxc.mount.entry = /root/.local/share/waydroid/data data none rbind 0 0`).
#
# That path lives in the OUTER container's writable layer, which Wolf throws
# away and recreates on every app start. Everything the user installs into
# Android -- APKs, games, their OBB/save data, Google accounts, Magisk
# modules -- therefore vanished on every restart, while system.img and the
# overlay survived (they are on the /var/lib/waydroid volume).
#
# Fix: keep the real userdata on the persistent volume and point Waydroid's
# host data path at it. A symlink is enough -- LXC bind-mounts through it --
# but the target must live on the same persistence domain, so use the
# /var/lib/waydroid volume that is already mounted.
#
# Ordering matters: this MUST run before the container manager starts the
# nested container, otherwise Waydroid creates a fresh real directory at the
# host data path and a symlink can no longer replace it.
_persist_userdata() {
    local work="$1"
    local host_data="/root/.local/share/waydroid/data"
    local persist="${work}/userdata"

    # Already done (idempotent; cont-init.d re-runs on every restart).
    if [ -L "$host_data" ] && [ "$(readlink "$host_data")" = "$persist" ]; then
        gow_log "[userdata] already persisted at ${persist}"
        _userdata_report "$persist"
        return 0
    fi

    mkdir -p "$(dirname "$host_data")" "$persist" 2>/dev/null || true

    # Migrate whatever is already there, so the first run after this change
    # keeps the apps that were installed before it existed. Only copy when
    # the persistent side is still empty -- never clobber a populated store.
    if [ -d "$host_data" ] && [ ! -L "$host_data" ]; then
        if [ -z "$(ls -A "$persist" 2>/dev/null)" ]; then
            gow_log "[userdata] Migrating existing userdata -> ${persist}"
            # cp -a preserves ownership/SELinux-ish xattrs that Android's
            # files rely on. Trailing /. copies contents, not the dir.
            if cp -a "${host_data}/." "${persist}/" 2>/dev/null; then
                gow_log "[userdata] Migration complete"
            else
                gow_log "[userdata] WARNING: migration hit errors; continuing with"
                gow_log "[userdata]    whatever copied successfully"
            fi
        else
            gow_log "[userdata] Persistent store already populated; leaving it as-is"
            gow_log "[userdata]    (old container-local data at ${host_data} is unused)"
        fi
        rm -rf "$host_data"
    fi

    mkdir -p "$(dirname "$host_data")"
    if ln -sfn "$persist" "$host_data"; then
        gow_log "[userdata] ${host_data} -> ${persist}"
    else
        gow_log "[userdata] WARNING: could not symlink ${host_data}; Android apps"
        gow_log "[userdata]    will be lost when this container is recreated"
        return 0
    fi

    _userdata_report "$persist"
}

# Report size + installed package count so persistence is observable in the
# logs rather than something the user has to take on faith.
_userdata_report() {
    local persist="$1"
    [ -d "$persist" ] || return 0

    local sz
    sz=$(du -sm "$persist" 2>/dev/null | awk '{print $1}')
    [ -n "$sz" ] && gow_log "[userdata] on-disk size: ${sz}MB"

    # /data/app is where installed APKs land; counting dirs there is a cheap
    # proxy for "how much would be lost".
    local n
    n=$(find "${persist}/app" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
        gow_log "[userdata] ${n} installed app dir(s) preserved"
    else
        gow_log "[userdata] no apps installed yet"
    fi
}

_persist_userdata "$WAYDROID_WORK"

#########################################
# 4b-3. Re-own app data after an Android version change
#########################################
# Android assigns each app a uid from its package-name cache, and that mapping
# is NOT stable across Android versions. Swapping images therefore leaves the
# previous version's uid on every file the app owns, and the app -- now running
# under a new uid -- cannot write to its own data:
#
#     I sgame_unity: [CVersionUpdateAppAction.ClearDownloadedApk]:
#       System.UnauthorizedAccessException: Access to the path
#       '/storage/emulated/0/Android/data/com.tencent.tmgp.sgame/files/iips_download/app'
#       is denied. ---> System.IO.IOException: Permission denied
#     I sgame_unity: OnResourceError error:556793857
#
# which in-game surfaces as "resource pack upgrade failed, please restart"
# (Honor of Kings is where this was diagnosed; the cause is generic).
#
# Measured on this host: the game ran as uid 10133 under Android 13 while 1882
# files under media/0/Android/data/com.tencent.tmgp.sgame still belonged to
# 10126 from Android 17. com.tencent.tmgp.osgame had the same problem with uid
# 10003.
#
# Both the internal tree (userdata/data/<pkg>) and the external one
# (userdata/media/0/Android/data/<pkg>) must match the package's current uid.
# The current uid is simply whatever owns the internal dir, which Android
# creates with the right value at install time.
_waydroid_fix_stale_uids() {
    local base="$WAYDROID_WORK/userdata"
    [ -d "$base/data" ] || return 0

    local pkg internal want ext fixed=0
    for internal in "$base"/data/*/; do
        [ -d "$internal" ] || continue
        pkg=$(basename "$internal")
        want=$(stat -c '%u' "$internal" 2>/dev/null) || continue
        [ -n "$want" ] || continue

        # External storage mirrors the same ownership rules.
        for ext in "$base/media/0/Android/data/$pkg" "$base/media/0/Android/obb/$pkg"; do
            [ -d "$ext" ] || continue
            if [ -n "$(find "$ext" ! -uid "$want" -print -quit 2>/dev/null)" ]; then
                chown -R "${want}:1078" "$ext" 2>/dev/null \
                    && fixed=$((fixed+1))
            fi
        done
    done

    [ "$fixed" -gt 0 ] && \
        gow_log "[uid] re-owned ${fixed} app storage tree(s) to their current uid" \
        || gow_log "[uid] app storage ownership is consistent"
}

_waydroid_fix_stale_uids

#########################################
# 4c. Generate waydroid_base.prop if missing
#########################################
# This file is written ONLY by initializer.init() (initializer.py:164 ->
# helpers/lxc.make_base_props). It is not part of the image download; it is
# generated from the *host's* GPU/binder capabilities.
#
# Consequence: if /var/lib/waydroid is populated by hand (images copied in,
# config present, rootfs/ created by our layout repair) the file is missing,
# `is_initialized()` still returns True because it only checks cfg + rootfs,
# and the session then dies at runtime with:
#
#     RuntimeError: waydroid_base.prop Not found
#
# which surfaces as a black screen. Observed in practice.
#
# Rather than require the user to re-run the whole (network-heavy) `waydroid
# init`, we ask waydroid to do just this one step. make_base_props() probes
# DRM/binder, so it must run as root with binderfs already mounted -- both
# true at this point in the sequence.
#
# It must ALSO re-run when it already exists but is out of sync with the
# [properties] section of waydroid.cfg. make_base_props() is the only writer
# of this file, and it appends those properties last (lxc.py: "now
# append/override with values in [properties] section of waydroid.cfg"). So
# a cfg edit -- which is how libndk/ARM-translation props get set, or how
# ro.berberis.flags is tuned -- silently does nothing while waydroid_base.prop
# is already present. That produced a boot where the ARM libraries were in
# place but:
#
#     ro.product.cpu.abilist   = x86_64,x86        (no arm64-v8a)
#     ro.dalvik.vm.native.bridge = 0
#
# i.e. every arm64 APK refused to install, with no error pointing at the
# real cause. Detect it by comparing the cfg's [properties] keys/values
# against the generated file and regenerate on mismatch.
_base_props_in_sync() {
    local cfg="$1" props="$2"
    [ -f "$props" ] || return 1

    # Compare each key=value from the cfg's [properties] section against the
    # generated file. Any missing/mismatched entry means we must regenerate.
    python3 - "$cfg" "$props" <<'PYEOF'
import sys, configparser

cfg_path, props_path = sys.argv[1], sys.argv[2]

c = configparser.ConfigParser()
c.optionxform = str          # property keys are case-sensitive
try:
    c.read(cfg_path)
except Exception:
    sys.exit(1)

want = dict(c["properties"]) if c.has_section("properties") else {}

have = {}
try:
    with open(props_path) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                have[k] = v
except Exception:
    sys.exit(1)

# Exit 0 = in sync, 1 = needs regeneration.
sys.exit(0 if all(have.get(k) == v for k, v in want.items()) else 1)
PYEOF
}

if [ ! -f "${WAYDROID_WORK}/waydroid_base.prop" ]; then
    _base_props_reason="missing"
elif ! _base_props_in_sync "${WAYDROID_WORK}/waydroid.cfg" "${WAYDROID_WORK}/waydroid_base.prop"; then
    _base_props_reason="out of sync with [properties] in waydroid.cfg"
else
    _base_props_reason=""
fi

if [ -n "$_base_props_reason" ]; then
    if [ -d "${WAYDROID_WORK}/rootfs" ] && [ -f "${WAYDROID_WORK}/waydroid.cfg" ]; then
        gow_log "[layout] waydroid_base.prop ${_base_props_reason}; generating it"
        if python3 - <<'PYEOF' 2>&1 | sed 's/^/      /'
import sys
sys.path.insert(0, "/usr/lib/waydroid")
from tools import config
from tools.helpers import lxc

class Args:
    # make_base_props() reads a handful of attributes that normally come from
    # argparse in a full `waydroid init`. Supply them from waydroid.cfg, which
    # init already wrote, so the output matches what init would have produced.
    pass

a = Args()
a.work = "/var/lib/waydroid"
a.config = a.work + "/waydroid.cfg"
a.images_path = a.work + "/images"

cfg = config.load(a)
w = cfg["waydroid"]
a.vendor_type = w.get("vendor_type", "MAINLINE")
a.arch = w.get("arch", "x86_64")
a.system_ota = w.get("system_ota", "None")
a.vendor_ota = w.get("vendor_ota", "None")
a.system_channel = w.get("system_channel")
a.vendor_channel = w.get("vendor_channel")
a.binder = w.get("binder", "anbox-binder")
a.vndbinder = w.get("vndbinder", "anbox-vndbinder")
a.hwbinder = w.get("hwbinder", "anbox-hwbinder")

lxc.make_base_props(a)
print("waydroid_base.prop written")
PYEOF
        then
            gow_log "[layout] waydroid_base.prop generated"
        else
            gow_log "[layout] WARNING: could not generate waydroid_base.prop"
            gow_log "[layout]    The session will fail with 'waydroid_base.prop Not found'."
        fi
    fi
fi

#########################################
# 4d. Generate the LXC config if missing
#########################################
# Same class of problem as 4c, and the next thing to fail: the LXC container
# definition is written by initializer.init() (initializer.py:163 ->
# helpers/lxc.set_lxc_config). Placing images by hand skips it, so
# /var/lib/waydroid/lxc/waydroid/config never exists and LXC has nothing to
# boot. The failure is visible only in LXC's own log:
#
#     lxc-start: waydroid: Failed to mount "tmpfs" on "/run/xdg": No such device
#     lxc-start: waydroid: Failed to setup mount entries
#     OSError: container failed to start
#
# set_lxc_config() concatenates version-appropriate snippets from
# /usr/lib/waydroid/data/configs/ and copies the seccomp profile. Calling it
# is safer than hand-writing a config, because it keeps the LXC-version
# handling that upstream already got right.
if [ ! -f "${WAYDROID_WORK}/lxc/waydroid/config" ]; then
    gow_log "[layout] LXC config missing; generating it"

    # Assembled from the toolkit's own templates rather than by calling
    # helpers.lxc.set_lxc_config(). That function routes every step through
    # helpers.run -> run_core.core(), which depends on argparse-populated
    # attributes (sudo_timer) and the toolkit logging layer
    # (logging.verbose). Reproducing that bootstrap from a shell script is
    # fragile and fails silently when an attribute is missing, which is
    # exactly what happened here. The templates are a plain concatenation,
    # so doing it directly is both simpler and verifiable.
    _lxc_src=/usr/lib/waydroid/data/configs
    if [ -f "${_lxc_src}/config_base" ]; then
        mkdir -p "${WAYDROID_WORK}/lxc/waydroid"
        _lxc_cfg="${WAYDROID_WORK}/lxc/waydroid/config"

        # config_base + the version-appropriate snippets.
        #
        # Version handling matters: config_1 is for LXC v1/v2 and uses the
        # pre-3.0 key name `lxc.utsname`, which LXC 6 rejects outright:
        #     Unsupported config key "lxc.utsname"
        #     Failed to create lxc_container
        # config_3 uses the modern `lxc.uts.name`. Upstream's set_lxc_config
        # picks config_1 only when lxc_ver <= 2, so mirror that logic rather
        # than concatenating everything.
        cat "${_lxc_src}/config_base" > "$_lxc_cfg"

        _lxc_ver="$(lxc-start --version 2>/dev/null | head -1)"
        _lxc_major="${_lxc_ver%%.*}"
        case "$_lxc_major" in
            ''|*[!0-9]*) _lxc_major=6 ;;   # unknown -> assume modern
        esac

        if [ "$_lxc_major" -le 2 ]; then
            [ -f "${_lxc_src}/config_1" ] && cat "${_lxc_src}/config_1" >> "$_lxc_cfg"
        else
            # LXC 3+ : apply every snippet from 3 up to the running major.
            for _v in 3 4 5 6 7; do
                [ "$_v" -le "$_lxc_major" ] || continue
                [ -f "${_lxc_src}/config_${_v}" ] && cat "${_lxc_src}/config_${_v}" >> "$_lxc_cfg"
            done
        fi

        # LXCARCH placeholder -> the machine architecture.
        sed -i "s/LXCARCH/$(uname -m)/" "$_lxc_cfg"

        # NOTE: the per-session hostname override deliberately does NOT live
        # here. This block only runs when the LXC config is MISSING, and the
        # config persists on the data volume, so anything written here would
        # never take effect on a normal start. It runs unconditionally after
        # the guard instead -- see section 4d-bis below.

        # seccomp profile referenced by the config.
        if [ -f "${_lxc_src}/waydroid.seccomp" ]; then
            cp -f "${_lxc_src}/waydroid.seccomp" \
                  "${WAYDROID_WORK}/lxc/waydroid/waydroid.seccomp"
        fi

        # config_nodes: `config` does `lxc.include .../config_nodes`, so LXC
        # refuses to parse the container at all when it is missing:
        #     Failed to parse config file ... at line "lxc.include = ..."
        # set_lxc_config() writes it via generate_nodes_lxc_config(), which is
        # a pure function (no subprocess, no logging bootstrap) and therefore
        # safe to call directly -- unlike set_lxc_config() itself.
        if [ ! -f "${WAYDROID_WORK}/lxc/waydroid/config_nodes" ]; then
            if python3 - <<'PYEOF' 2>&1 | sed 's/^/      /'
import sys, os
sys.path.insert(0, "/usr/lib/waydroid")
from tools import config
from tools.helpers import lxc

class Args:
    pass

a = Args()
a.work = "/var/lib/waydroid"
a.config = a.work + "/waydroid.cfg"
a.images_path = a.work + "/images"

cfg = config.load(a)
w = cfg["waydroid"]
a.vendor_type = w.get("vendor_type", "MAINLINE")
a.arch = w.get("arch", "x86_64")

# generate_nodes_lxc_config() reads the binder driver names that
# config.setup_config() normally records. Supply them from waydroid.cfg so
# the generated entries match what a completed `waydroid init` would emit.
a.BINDER_DRIVER = w.get("binder", "anbox-binder")
a.VNDBINDER_DRIVER = w.get("vndbinder", "anbox-vndbinder")
a.HWBINDER_DRIVER = w.get("hwbinder", "anbox-hwbinder")

nodes = lxc.generate_nodes_lxc_config(a)
out = "/var/lib/waydroid/lxc/waydroid/config_nodes"
with open(out, "w") as f:
    f.writelines(n + "\n" for n in nodes)
print("config_nodes written (%d entries)" % len(nodes))
PYEOF
            then
                gow_log "[layout] config_nodes generated"
            else
                gow_log "[layout] WARNING: could not generate config_nodes"
            fi
        fi

        # config_session: an empty placeholder is enough; waydroid fills it in
        # at session start via generate_session_lxc_config().
        [ -f "${WAYDROID_WORK}/lxc/waydroid/config_session" ] || \
            : > "${WAYDROID_WORK}/lxc/waydroid/config_session"

        if [ -f "$_lxc_cfg" ]; then
            gow_log "[layout] LXC config generated ($(wc -l < "$_lxc_cfg") lines)"
        fi
    else
        gow_log "[layout] WARNING: LXC templates missing at ${_lxc_src}"
    fi
fi

#########################################
# 4d-bis. Per-session guest hostname (audio isolation)
#########################################
# MUST run on EVERY start, so it sits deliberately OUTSIDE the guard above:
# that block only regenerates the LXC config when it is missing, and the config
# lives on the data volume, so on a normal start the guard is skipped entirely
# and anything inside it never executes. (That was the first attempt at this
# fix, and it silently did nothing -- the guest kept the hostname "waydroid".)
#
# Why the hostname matters:
#
# Waydroid hardcodes `lxc.uts.name = waydroid` (see configs/config_3), so EVERY
# Waydroid container's Android guest reports the hostname "waydroid". libpulse
# copies that into the client property `application.process.host`, and Wolf's
# pulse router identifies which session a playback stream belongs to using
# exactly that property (src/moonlight-server/audio/pulse_router.cpp):
#
#     const char *host = pa_proplist_gets(info->proplist,
#                                         "application.process.host");
#     if (!host || host[0] == '\0') return;   // unmatched -> NOT routed
#     ... host_to_session.find(host) ...
#     pa_context_move_sink_input_by_index(c, info->index, target, ...);
#
# Wolf's map is keyed by the CONTAINER hostname:
#     [PULSE_ROUTER] Map add host='01688ede1710' -> session='...'
#
# so "waydroid" never matches and the stream is never moved to its own
# virtual_sink_<session>. Measured on a live host: 31 `Map add` lines and ZERO
# `Move sink-input` lines -- routing had never once succeeded.
#
# Consequence with more than one session: every stream stays on whatever sink
# is the PulseAudio DEFAULT. One device then receives all the audio and the
# other receives none -- observed both as cross-talk and as a device with no
# sound at all.
#
# Setting the UTS name to this container's own hostname makes the property
# equal the map key, so each session's audio is routed to its own sink.
# Override with WAYDROID_GUEST_HOSTNAME=<value>.
_lxc_cfg_persist="${WAYDROID_WORK}/lxc/waydroid/config"
if [ -f "$_lxc_cfg_persist" ]; then
    _g_host="${WAYDROID_GUEST_HOSTNAME:-$(hostname 2>/dev/null)}"
    if [ -n "$_g_host" ]; then
        if grep -q '^lxc\.uts\.name[[:space:]]*=' "$_lxc_cfg_persist"; then
            sed -i "s|^lxc\.uts\.name[[:space:]]*=.*|lxc.uts.name = ${_g_host}|" "$_lxc_cfg_persist"
        else
            printf 'lxc.uts.name = %s\n' "$_g_host" >> "$_lxc_cfg_persist"
        fi
        gow_log "[audio] guest hostname set to ${_g_host} (per-session pulse routing)"
    else
        gow_log "[audio] WARNING: could not determine hostname; audio may cross sessions"
    fi
else
    gow_log "[audio] WARNING: no LXC config at ${_lxc_cfg_persist}; cannot set guest hostname"
fi


#########################################
# 4e. Make the LXC "dev" mount entry absolute
#########################################
# Waydroid's generated config_nodes contains a RELATIVE mount entry:
#
#     lxc.mount.entry = tmpfs dev tmpfs nosuid 0 0
#
# Relative entries are resolved against liblxc's staging rootfs
# (/usr/lib/<triplet>/lxc/rootfs), which LXC builds inside a private mount
# namespace. With `lxc.autodev = 0` (which Waydroid sets) LXC does not create
# the staging `dev/`, so the mount fails:
#
#     Failed to mount "tmpfs" on "/usr/lib/x86_64-linux-gnu/lxc/rootfs/dev"
#     No such file or directory
#     OSError: container failed to start
#
# Isolated with a minimal 5-line LXC config: identical settings succeed with
# autodev at its default and fail with autodev=0. Rewriting the target as an
# absolute path under the real rootfs makes LXC create it via create=dir and
# the mount succeeds -- verified: 0 mount failures, LXC proceeds to spawn.
#
# Only the `dev` entry needs this: every other relative entry in
# config_nodes/config_session lists a file with create=file (which LXC
# creates), whereas the tmpfs entry has no such flag.
_waydroid_fix_lxc_mounts() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0

    local rootfs="${WAYDROID_WORK}/rootfs"
    local changed=0

    # Rewrite RELATIVE mount targets into absolute ones under the real rootfs.
    #
    # LXC resolves a relative target against its private staging rootfs
    # (/usr/lib/<triplet>/lxc/rootfs), which it builds inside its own mount
    # namespace. In a container that staging tree is not populated the way it
    # is on a host -- verified: even with autodev enabled, relative entries
    # such as "dev/binder" and "run/xdg/pulse/native" fail with
    #     Failed to mount "/dev/anbox-binder" onto
    #       "/usr/lib/.../lxc/rootfs/dev/binder": No such file or directory
    # while the SAME config with an absolute target succeeds and LXC proceeds
    # to exec init.
    #
    # Entry format (note the two literal spaces around the target and the
    # trailing "0 0"): lxc.mount.entry = <src> <target> <fstype> <opts> 0 0
    # A tmpfs entry has fstype "tmpfs" and no source.
    local tmp
    tmp="$(mktemp)"
    while IFS= read -r line; do
        # keep any leading text before the entry (comments, blanks)
        case "$line" in
            "lxc.mount.entry = "*)
                local body="${line#lxc.mount.entry = }"
                local src target fstype opts
                src="$(printf '%s' "$body"  | awk '{print $1}')"
                target="$(printf '%s' "$body" | awk '{print $2}')"
                fstype="$(printf '%s' "$body" | awk '{print $3}')"
                opts="$(printf '%s' "$body"   | awk '{print $4}')"
                # Skip if already absolute, or already rewritten by a
                # previous run (a restarted container reuses the config).
                case "$target" in
                    "${rootfs}"/*) printf '%s\n' "$line" >> "$tmp"; continue ;;
                esac
                if [ -n "$target" ] && [ "${target#/}" = "$target" ]; then
                    # relative -> absolute
                    mkdir -p "${rootfs}/$(dirname "$target")" 2>/dev/null || true
                    # for a file target, pre-create it so the bind can land
                    case "$opts" in
                        *create=file*) mkdir -p "${rootfs}/${target}" 2>/dev/null || true ;;
                        *)             mkdir -p "${rootfs}/${target}" 2>/dev/null || true ;;
                    esac
                    printf 'lxc.mount.entry = %s %s/%s %s %s 0 0\n' \
                        "$src" "$rootfs" "$target" "$fstype" "$opts" >> "$tmp"
                    changed=$((changed + 1))
                    continue
                fi
                ;;
        esac
        printf '%s\n' "$line" >> "$tmp"
    done < "$cfg"

    if [ "$changed" -gt 0 ]; then
        cat "$tmp" > "$cfg"
        gow_log "[layout] Rewrote ${changed} relative LXC mount(s) in $(basename "$cfg")"
    fi
    rm -f "$tmp"
}

_waydroid_fix_lxc_mounts "${WAYDROID_WORK}/lxc/waydroid/config_nodes"
_waydroid_fix_lxc_mounts "${WAYDROID_WORK}/lxc/waydroid/config_session"

#########################################
# 4f. Give Android the DRM card node too, not just the render node
#########################################
# Waydroid's generate_nodes_lxc_config() passes only the RENDER node into the
# nested container:
#
#     render, _ = tools.helpers.gpu.getDriNode(args)     # helpers/lxc.py
#     make_entry(render)
#
# The card node is computed and then deliberately discarded. That is enough for
# OpenGL ES -- gralloc allocates through the render node and the game's EGL
# context works fine -- but Vulkan needs the card node to create its swapchain
# and present, so any Vulkan-based renderer silently falls back to GL:
#
#     Unity : set vulkan allow: False
#
# which is what a title like Genshin Impact (com.miHoYo.Yuanshen) reports on
# this host: the only choice offered is OpenGL, and CPU load climbs because the
# GL path is doing work the GPU should be doing.
#
# Symptom in the container: /dev/dri holds renderD128 but no cardN at all,
# even though the host (and the outer Wolf container) have both.
#
# Fix: mirror the card node that belongs to the same DRM device as the render
# node Waydroid picked. getDriNode() already knows how to derive it
# (/sys/class/drm/renderD128/device/drm/card1), it just throws it away, so we
# re-derive it the same way and append the missing mount entry.
#
# Idempotent: the entry is only added when absent.
_waydroid_add_card_node() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0

    local rootfs="${WAYDROID_WORK}/rootfs"

    # The mount target is a FILE inside a directory that LXC creates itself
    # (dev/ is a tmpfs it mounts). `create=file` cannot create missing parent
    # directories, and the entry is `optional 0 0`, so when dev/dri/ is absent
    # the bind silently does nothing -- the container boots and the card node
    # is simply missing. Create the directory unconditionally, BEFORE the
    # idempotency check below can short-circuit us, because the check may pass
    # on a config written by an earlier run while the directory is still gone
    # (this is exactly what happened: hand-added entry + missing dir).
    mkdir -p "${rootfs}/dev/dri" 2>/dev/null || true

    local render="" card=""
    # The source field may already have been rewritten to an absolute path
    # under the rootfs by _waydroid_fix_lxc_mounts(), so match on the basename
    # rather than the whole path.
    render="$(awk '/^lxc\.mount\.entry = .*\/dev\/dri\/renderD[0-9]+ /{print $4}' "$cfg" | head -1)"
    [ -n "$render" ] || return 0

    # Already mapped?
    grep -qE "^lxc\.mount\.entry = .*/dev/dri/card[0-9]+ " "$cfg" && return 0

    local rname
    rname="$(basename "$render")"
    # Same lookup Waydroid uses: the cardN sitting under this render node's
    # device directory.
    card="$(ls -d /sys/class/drm/"${rname}"/device/drm/card[0-9]* 2>/dev/null | sort | head -1)"
    if [ -z "$card" ]; then
        gow_log "[dri] WARNING: no card node found for ${rname}; Vulkan will be unavailable"
        return 0
    fi
    card="/dev/dri/$(basename "$card")"

    if [ ! -e "$card" ]; then
        gow_log "[dri] WARNING: ${card} missing in this container; Vulkan will be unavailable"
        gow_log "[dri]    Pass --device=$card (Wolf: GOW_REQUIRED_DEVICES)"
        return 0
    fi

    # The mount target must be absolute under the real rootfs, matching what
    # _waydroid_fix_lxc_mounts() produced for the render node. (dev/dri/ was
    # created at the top of this function.)
    printf 'lxc.mount.entry = %s %s/dev/dri/%s none bind,create=file,optional 0 0\n' \
        "$card" "$rootfs" "$(basename "$card")" >> "$cfg"
    gow_log "[dri] Mapped ${card} into Android (enables Vulkan; render node alone is not enough)"
}

_waydroid_add_card_node "${WAYDROID_WORK}/lxc/waydroid/config_nodes"


#########################################
# 4g. Single-GPU pinning (multi-GPU hosts)
#########################################
# On a host with more than one DRM device, Waydroid and Mesa do NOT agree on
# which GPU to use, and the disagreement shows up as a torn/garbled picture:
#
#   * Waydroid's getDriNode() walks /dev/dri/renderD* in *sorted* order and
#     returns the first non-nvidia node. On this host that is renderD128, which
#     happens to be the DISCRETE card (PCI 1002:7590, boot_vga=0).
#   * Mesa inside Android does its own enumeration and auto-selects the
#     *fastest* GPU, i.e. that same discrete card -- but gralloc.gbm.device was
#     pinned to whatever Waydroid chose, and SurfaceFlinger's EGL context can
#     land on the other one (the primary Renoir iGPU, 1002:1638, boot_vga=1).
#
# The result is buffers allocated on one GPU and composited on the other. With
# no PRIME/cross-device import path wired up in the Android gralloc stack, the
# frames come out scrambled.
#
# Android 13 never hit this because only a single render node was exposed. The
# lineage-24.0 image enumerates every node, which is what surfaced it.
#
# The reliable fix is to make exactly ONE GPU visible to Android, so there is
# nothing to disagree about. We pick:
#
#   1. WAYDROID_DRM_DEVICE, if set (e.g. /dev/dri/renderD129), else
#   2. the node Waydroid already chose in config_nodes, else
#   3. the primary/boot GPU (`boot_vga=1`), else
#   4. the first render node.
#
# Only the chosen render node and its matching card node are kept; every other
# /dev/dri/renderD* and cardN mount is dropped from the nested container. The
# outer Wolf container is untouched, so its own compositor keeps both GPUs.
#
# Set WAYDROID_MULTI_GPU=keep to opt out and pass every node through.
_waydroid_pin_single_gpu() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0

    [ "${WAYDROID_MULTI_GPU:-pin}" = "keep" ] && return 0

    # Count the DRM nodes actually visible to us. A single-GPU host is already
    # unambiguous -- leave it alone so we never perturb the common case.
    local all_nodes n_nodes
    all_nodes="$(ls -d /dev/dri/renderD[0-9]* 2>/dev/null)"
    n_nodes="$(printf '%s\n' "$all_nodes" | grep -c .)"
    [ "$n_nodes" -gt 1 ] || return 0

    local chosen=""
    if [ -n "${WAYDROID_DRM_DEVICE:-}" ] && [ -e "${WAYDROID_DRM_DEVICE}" ]; then
        chosen="${WAYDROID_DRM_DEVICE}"
    else
        # Authoritative source: `drm_device` from waydroid.cfg.
        #
        # That is the node Waydroid's own session uses for its GBM/Wayland
        # display, so the renderer and gralloc MUST agree with it. Reading the
        # LXC mount entry instead (the previous behaviour) allowed the two to
        # drift apart, because the mount entry is ours to rewrite while
        # drm_device belongs to Waydroid. Observed drift:
        #
        #     drm_device         = /dev/dri/renderD129   (iGPU)
        #     gralloc.gbm.device = renderD128            (discrete)
        #
        # That is a cross-GPU buffer hand-off between two AMD cards, which
        # shows up as 花屏 / screen corruption. Always trust drm_device.
        chosen="$(awk -F'=[[:space:]]*' '/^drm_device[[:space:]]*=/{print $2; exit}' \
                  "${WAYDROID_WORK}/waydroid.cfg" 2>/dev/null)"
        chosen="$(basename "${chosen:-}")"
        [ -n "$chosen" ] && chosen="/dev/dri/$chosen"
        if [ -z "$chosen" ] || [ ! -e "$chosen" ]; then
            # Fall back to what Waydroid wrote into the LXC config.
            chosen="$(awk '/^lxc\.mount\.entry = .*\/dev\/dri\/renderD[0-9]+ /{print $4}' "$cfg" | head -1)"
            chosen="$(basename "${chosen:-}")"
            [ -n "$chosen" ] && chosen="/dev/dri/$chosen"
        fi
    fi

    # Fall back to the boot/primary GPU, which is the one the display is
    # actually attached to.
    if [ -z "$chosen" ] || [ ! -e "$chosen" ]; then
        local node
        for node in $all_nodes; do
            if [ "$(cat "/sys/class/drm/$(basename "$node")/device/boot_vga" 2>/dev/null)" = "1" ]; then
                chosen="$node"
                break
            fi
        done
    fi
    [ -n "$chosen" ] && [ -e "$chosen" ] || chosen="$(printf '%s\n' "$all_nodes" | head -1)"

    local rname chosen_card
    rname="$(basename "$chosen")"
    # Publish the resolved node for section 4i-bis, which pins Mesa's EGL/GL
    # device inside Android. Deriving DRI_PRIME from the SAME variable that
    # sets gralloc.gbm.device is what guarantees the renderer and the display
    # allocator can never end up on different GPUs.
    export WAYDROID_RENDER_NODE_RESOLVED="$rname"
    chosen_card="$(ls -d /sys/class/drm/"${rname}"/device/drm/card[0-9]* 2>/dev/null | sort | head -1)"
    chosen_card="/dev/dri/$(basename "${chosen_card:-}")"

    local rootfs="${WAYDROID_WORK}/rootfs"
    mkdir -p "${rootfs}/dev/dri" 2>/dev/null || true

    # Drop every DRI mount, then re-add only the chosen render+card pair.
    # `create=file` means the mount silently no-ops when the source is absent,
    # so removing the entries is what actually hides the extra GPUs.
    local tmp
    tmp="$(mktemp)"
    grep -vE '^lxc\.mount\.entry = .*/dev/dri/(renderD[0-9]+|card[0-9]+) ' "$cfg" > "$tmp" || true
    mv "$tmp" "$cfg"

    local entry
    for entry in "$chosen" "$chosen_card"; do
        [ -n "$entry" ] && [ -e "$entry" ] || continue
        printf 'lxc.mount.entry = %s %s/dev/dri/%s none bind,create=file,optional 0 0\n' \
            "$entry" "$rootfs" "$(basename "$entry")" >> "$cfg"
    done

    # ------------------------------------------------------------------
    # Also pass through EVERY DRM node the host exposes.
    # ------------------------------------------------------------------
    # Mesa's loader (libgallium_dri.so) does NOT take a node name from a
    # property. It walks /sys/class/drm, reads each card's PCI id, and then
    # tries to open the matching /dev/dri/<name>. Inside the LXC, /sys is
    # bind-mounted READ-ONLY from the host, so it advertises every GPU the
    # host has -- but only the nodes we bind-mount into /dev/dri exist.
    #
    # That mismatch is fatal. Measured inside the guest:
    #
    #     /sys/class/drm : card1 card2 renderD128 renderD129 (+ connectors)
    #     /dev/dri       : card2 renderD129            <-- only the pinned pair
    #
    #     /sys/class/drm/card1 -> 0x1002:0x7590  (discrete)
    #     /sys/class/drm/card2 -> 0x1002:0x1638  (iGPU)
    #
    # So the loader reads card1 from sysfs, tries /dev/dri/card1, and fails.
    # libgallium_dri.so then logs exactly what we see:
    #
    #     failed to get driver name for fd -1
    #     MESA-LOADER: failed to retrieve device information
    #
    # and EGL falls back to a configless path -- which is why Unity reports
    # EGL_BAD_CONFIG and no layer ever receives a buffer (every SurfaceFlinger
    # layer shows "buffer: slot=-1 buffer=0x0", and screencap is pure black).
    #
    # Binding all four nodes makes /dev/dri agree with /sys/class/drm. Mesa can
    # then open whichever card it enumerates, and DRI_PRIME (below) still
    # decides which one is actually used, so this does not reintroduce the
    # cross-GPU split the pinning was added to prevent.
    local _node
    for _node in /dev/dri/card[0-9]* /dev/dri/renderD[0-9]*; do
        [ -e "$_node" ] || continue
        grep -q "/dev/dri/$(basename "$_node") " "$cfg" && continue
        printf 'lxc.mount.entry = %s %s/dev/dri/%s none bind,create=file,optional 0 0\n' \
            "$_node" "$rootfs" "$(basename "$_node")" >> "$cfg"
    done
    gow_log "[dri] passed through all host DRM nodes so /dev/dri matches /sys/class/drm"

    # Removing the mount entries is NOT sufficient on its own: Android's
    # ueventd recreates /dev/dri/renderD* from sysfs on boot, so Mesa still
    # enumerates every GPU and keeps auto-selecting the fastest (discrete) one
    # for its EGL context -- while gralloc.gbm.device points at the node we
    # pinned. That is the same split we are trying to remove.
    #
    # Mesa reads DRI_PRIME to override its choice. Pinning it to the chosen
    # GPU's PCI address makes every Mesa client inside Android (SurfaceFlinger,
    # gralloc's EGL, app GL contexts) use one device.
    #
    # Format is pci-<vendor>_<device>_<subvendor>_<subdevice>; the simpler
    # `pci-<domain>_<bus>_<slot>_<func>` form is accepted too. We derive the
    # vendor:device pair from the chosen node's sysfs uevent.
    local pci_id dri_prime=""
    pci_id="$(awk -F= '/^PCI_ID=/{print $2}' "/sys/class/drm/${rname}/device/uevent" 2>/dev/null)"
    if [ -n "$pci_id" ]; then
        local vdev vdr
        vdev="${pci_id%%:*}"   # vendor
        vdr="${pci_id##*:}"    # device
        dri_prime="pci-${vdev}_${vdr}"
    fi

    # lxc.environment entries must be added to the per-container config; keep
    # this idempotent so repeated boots do not stack duplicates.
    local lxccfg="${WAYDROID_WORK}/lxc/waydroid/config"
    if [ -n "$dri_prime" ] && [ -f "$lxccfg" ]; then
        sed -i '/^lxc\.environment = DRI_PRIME=/d' "$lxccfg"
        printf 'lxc.environment = DRI_PRIME=%s\n' "$dri_prime" >> "$lxccfg"
        gow_log "[dri] Pinned Mesa to ${dri_prime} via DRI_PRIME (single-GPU rendering)"
    fi

    # RADV (the AMD Vulkan driver) reads DRI_PRIME for GLES/EGL, but Vulkan
    # device selection is driven by MESA_VK_DEVICE_SELECT instead. Pin the same
    # GPU for Vulkan so a game's Vulkan context lands on the chosen node and not
    # the other AMD card. The value is the same pci-<vendor>_<device> token.
    if [ -n "$dri_prime" ] && [ -f "$lxccfg" ]; then
        sed -i '/^lxc\.environment = MESA_VK_DEVICE_SELECT=/d' "$lxccfg"
        printf 'lxc.environment = MESA_VK_DEVICE_SELECT=%s\n' "$dri_prime" >> "$lxccfg"
        gow_log "[dri] Pinned Vulkan (RADV) to ${dri_prime} via MESA_VK_DEVICE_SELECT"
    fi

    # ------------------------------------------------------------------
    # Pin gralloc.gbm.device to the chosen GPU's RENDER node.
    # ------------------------------------------------------------------
    # Waydroid's own tools/helpers/lxc.py does:
    #     dri, _ = getDriNode(args)            # -> /dev/dri/renderD129
    #     props.append("gralloc.gbm.device=" + dri)
    # so the render node is the upstream default, and it is the value that must
    # be kept. Do NOT "improve" this to a card node.
    #
    # A previous revision forced a /dev/dri/card* node here, on the theory that
    # libminigbm_gralloc_gbm_mesa.so resolves its device from a "/dev/dri/card*"
    # template. The library does accept both patterns when opening the node --
    # but the AMD userspace driver that receives it next does not. From
    # libdrm_amdgpu.so, amdgpu_device_initialize():
    #
    #     82e1: call drmGetNodeTypeFromFd
    #     82e9: cmp  $0x2,%eax        ; DRM_NODE_RENDER
    #     82ec: je   ...              ; render node -> accepted
    #          (anything else falls through to an ioctl that fails)
    #
    # Node types: PRIMARY=0 (card*), CONTROL=1, RENDER=2 (renderD*).
    #
    # Handed a card node, Mesa logs exactly this and gives up:
    #
    #     E MESA: amdgpu: amdgpu_device_initialize failed.
    #     W EGL-MAIN: failed to get driver name for fd -1
    #     W EGL-MAIN: MESA-LOADER: failed to retrieve device information
    #
    # Every process then fails to obtain a usable EGL config, no layer ever
    # queues a buffer (SurfaceFlinger shows "buffer: slot=-1 buffer=0x0" and
    # "composition type=INVALID"), and the framebuffer is entirely black.
    #
    # Both drm_device and gralloc.gbm.device therefore point at the same RENDER
    # node. WAYDROID_GRALLOC_DEVICE=<node> overrides for experiments.
    local wcfg="${WAYDROID_WORK}/waydroid.cfg"
    if [ -n "$chosen_card" ] && [ -e "$chosen_card" ] && [ -f "$wcfg" ]; then
        # On Android <= 15 (the pre-berberis ndk_translation images) the
        # known-good configuration on this host used the RENDER node that
        # Waydroid's own lxc.py picks (renderD129), not a card node. The
        # card-node rewrite below was introduced later, to fix cross-GPU
        # flicker on the Android 16/17 images, and applying it to A13
        # deviates from a configuration that is known to boot. So only do
        # the rewrite when the installed image is Android 16+.
        local _rel=""
        if [ -f "${WAYDROID_WORK}/images/vendor.img" ] && command -v debugfs >/dev/null 2>&1; then
            _rel="$(debugfs -R "cat build.prop" "${WAYDROID_WORK}/images/vendor.img" 2>/dev/null \
                | sed -n 's/^ro\.vendor\.build\.version\.release=//p' | head -1)"
        fi

        if [ -n "$_rel" ] && [ "$_rel" -lt 16 ] 2>/dev/null; then
            # Android <= 15: leave gralloc.gbm.device exactly as waydroid.cfg
            # specifies. Override with WAYDROID_GRALLOC_DEVICE=<node> to pin a
            # different node (used when debugging the black-screen/graphics
            # path, where the Mesa GBM backend reporting "fd -1" suggests it
            # never managed to open a device).
            if [ -n "${WAYDROID_GRALLOC_DEVICE:-}" ]; then
                if grep -q '^gralloc\.gbm\.device' "$wcfg"; then
                    sed -i "s|^gralloc\.gbm\.device = .*|gralloc.gbm.device = ${WAYDROID_GRALLOC_DEVICE}|" "$wcfg"
                else
                    printf 'gralloc.gbm.device = %s\n' "$WAYDROID_GRALLOC_DEVICE" >> "$wcfg"
                fi
                gow_log "[dri] Android ${_rel}: gralloc.gbm.device forced to ${WAYDROID_GRALLOC_DEVICE}"
            else
                # Force gralloc onto the SAME render node we chose -- and we
                # now choose that node from waydroid.cfg's drm_device. Leaving
                # the file value alone (the old behaviour) is precisely how
                # gralloc ended up on renderD128 while drm_device said
                # renderD129, i.e. 花屏 from a cross-GPU buffer hand-off.
                if grep -q '^gralloc\.gbm\.device' "$wcfg"; then
                    sed -i "s|^gralloc\.gbm\.device = .*|gralloc.gbm.device = ${rname}|" "$wcfg"
                else
                    printf 'gralloc.gbm.device = %s\n' "$rname" >> "$wcfg"
                fi
                gow_log "[dri] Android ${_rel}: gralloc.gbm.device=${rname} (matched to drm_device)"
            fi
        else
            # Android 16+: keep the RENDER node here too. See the note above
            # _waydroid_pick_hal_modules / the amdgpu explanation below:
            # amdgpu_device_initialize() rejects anything that is not a
            # DRM_NODE_RENDER, so handing Mesa a card* node makes the AMD
            # driver fail to initialise and the display stays black.
            #
            # WAYDROID_GRALLOC_DEVICE=<node> overrides, for experiments only.
            local _want="${WAYDROID_GRALLOC_DEVICE:-$rname}"
            if grep -q '^gralloc\.gbm\.device' "$wcfg"; then
                sed -i "s|^gralloc\.gbm\.device = .*|gralloc.gbm.device = ${_want}|" "$wcfg"
            else
                printf 'gralloc.gbm.device = %s\n' "$_want" >> "$wcfg"
            fi
            gow_log "[dri] gralloc.gbm.device -> ${_want} (render node; amdgpu requires DRM_NODE_RENDER)"
        fi
    fi

    gow_log "[dri] Multiple DRM devices present; pinning Android to ${rname} ($(basename "${chosen_card:-none}"))"

    # ------------------------------------------------------------------
    # Make the chosen CARD node openable by Android's graphics processes.
    # ------------------------------------------------------------------
    # Waydroid's own session start only relaxes the RENDER nodes. Its log shows:
    #
    #     % chmod 777 -R /dev/dri/renderD129
    #     % chmod 777 -R /dev/dri/renderD128
    #
    # and nothing for card*. On this host card* is created 0660 root:root while
    # renderD* is 0666, so once gralloc.gbm.device points at a card node the
    # Mesa GBM backend and SurfaceFlinger -- which run as the unprivileged
    # `ubuntu` (uid 1000/gid 1003) user inside Android, NOT as root -- cannot
    # open it. Observed consequences:
    #
    #     W EGL-MAIN: failed to get driver name for fd -1
    #     W EGL-MAIN: MESA-LOADER: failed to retrieve device information
    #       -> Mesa never gets a device, so gbm_create_device() fails
    #       -> no allocatable buffers -> nothing reaches the display
    #     (screencap of the live framebuffer was 100% black)
    #
    # It also matters AFTER the switch: SurfaceFlinger kept renderD129 open
    # while gralloc was told to use card2, which is exactly the cross-device
    # split the A16 flicker fix describes.
    #
    # chmod 666 rather than 777: these are character devices, the execute bit
    # is meaningless, and 666 still restricts access to the container.
    if [ -n "${chosen_card:-}" ] && [ -e "/dev/dri/$(basename "$chosen_card")" ]; then
        chmod 666 "/dev/dri/$(basename "$chosen_card")" 2>/dev/null \
            && gow_log "[dri] $(basename "$chosen_card") opened to Android graphics (was root-only)"
    fi
    # Belt and braces: also relax every node we hand to Android.
    for _n in /dev/dri/renderD* /dev/dri/card*; do
        [ -e "$_n" ] || continue
        chmod 666 "$_n" 2>/dev/null || true
    done
}

# ----------------------------------------------------------------------
# Select the gralloc / hwcomposer / memtrack HAL module names for the
# installed Android version.
# ----------------------------------------------------------------------
# The module filename the HAL loader looks for is
#     <class>.<ro.hardware.<class>>.so
# and the set of modules actually shipped DIFFERS between images:
#
#   Android 16/17 vendor/lib64/hw/:
#       gralloc.minigbm.so              <-- present
#       gralloc.minigbm_gbm_mesa.so     <-- present
#   Android 13 vendor/lib64/hw/:
#       gralloc.minigbm_gbm_mesa.so     <-- present
#       gralloc.minigbm.so              <-- ABSENT
#
# So `ro.hardware.gralloc=minigbm` is correct on A16/17 but on A13 resolves to
# gralloc.minigbm.so, which does not exist, and the graphics stack fails to come
# up (surfaceflinger never gets a working allocator; screen stays black).
# The known-good A13 configuration on this host used minigbm_gbm_mesa.
#
# Rather than hardcode, probe the module directories in the vendor image and
# pick the first candidate that actually exists. This keeps working across
# images without having to remember which spelling each one wants.
_waydroid_pick_hal_modules() {
    local vimg="${WAYDROID_WORK}/images/vendor.img"
    local wcfg="${WAYDROID_WORK}/waydroid.cfg"
    [ -f "$vimg" ] && [ -f "$wcfg" ] || return 0
    command -v debugfs >/dev/null 2>&1 || return 0

    local _listing
    _listing="$(debugfs -R "ls -l /lib64/hw" "$vimg" 2>/dev/null)"
    [ -n "$_listing" ] || return 0

    _has() {
        printf '%s\n' "$_listing" | grep -q " $1\$"
    }

    _set_prop() {
        if grep -q "^$1 *=" "$wcfg"; then
            sed -i "s|^$1 *=.*|$1 = $2|" "$wcfg"
        else
            printf '%s = %s\n' "$1" "$2" >> "$wcfg"
        fi
    }

    # gralloc: prefer the mesa-gbm variant when present, else minigbm.
    local _g=""
    if   _has "gralloc.minigbm_gbm_mesa.so"; then _g="minigbm_gbm_mesa"
    elif _has "gralloc.minigbm.so";          then _g="minigbm"
    elif _has "gralloc.gbm.so";              then _g="gbm"
    fi
    [ -n "$_g" ] && { _set_prop "ro.hardware.gralloc" "$_g"; gow_log "[hal] ro.hardware.gralloc=${_g}"; }

    # hwcomposer / memtrack: only meaningful when the waydroid modules ship.
    if _has "hwcomposer.waydroid.so"; then
        _set_prop "ro.hardware.hwcomposer" "waydroid"
        gow_log "[hal] ro.hardware.hwcomposer=waydroid"
    fi
    if _has "memtrack.waydroid.so"; then
        _set_prop "ro.hardware.memtrack" "waydroid"
        gow_log "[hal] ro.hardware.memtrack=waydroid"
    fi
}

_waydroid_pick_hal_modules

_waydroid_pin_single_gpu "${WAYDROID_WORK}/lxc/waydroid/config_nodes"


#########################################
# 4g-bis. Make vendor HALs resolvable (Android 13 black-screen fix)
#########################################
# SYMPTOM: on Android 13 (lineage-20.0) the system boots but never finishes:
# sys.boot_completed is never set, the screen stays black, and system_server
# restarts in a loop. logcat -b crash shows, endlessly:
#
#   android.hardware.gatekeeper@1.0-service: Unable to open GateKeeper HAL
#   Abort message: 'Unable to open GateKeeper HAL'
#     #03 HIDL_FETCH_IGatekeeper+145  (android.hardware.gatekeeper@1.0-impl.so)
#     #02 __android_log_assert
#
# and gatekeeperd blocks waiting for it forever:
#
#   HidlServiceManagement: Waited one second for
#       android.hardware.gatekeeper@1.0::IGatekeeper/default
#
# ROOT CAUSE
# ----------
# The impl calls hw_get_module_by_class("gatekeeper", NULL, &module). With a
# NULL name, libhardware resolves the module file by trying these properties
# in order (see hardware/libhardware/hardware.c):
#
#     ro.hardware.gatekeeper  ->  ro.hardware  ->  ro.product.board
#     ->  ro.arch  ->  ro.board.platform
#
# The A13 vendor image ships exactly one usable module:
#
#     /vendor/lib64/hw/gatekeeper.waydroid.so
#
# but in the guest `ro.hardware` reads back as **unknown**, because Android's
# init sets ro.hardware from the kernel cmdline (androidboot.hardware) before
# any prop file is loaded, and ro.* properties are write-once. Waydroid's
# waydroid.prop asking for ro.hardware=waydroid therefore CANNOT take effect,
# and the lookup falls through to "gatekeeper.unknown.so", which does not
# exist -> abort.
#
# ro.hardware.gatekeeper is a *different* property: init never sets it, so it
# is still write-once-from-empty and CAN be supplied by waydroid.prop. Setting
# it makes the very first lookup step hit, resolving to gatekeeper.waydroid.so.
#
# Sanity check that the prop file really is the delivery mechanism: the guest
# reports ro.hardware.egl=mesa, and that value comes from this same file.
#
# WHY ANDROID 16/17 DID NOT NEED THIS
# -----------------------------------
# There, /system/bin/gatekeeperd is AIDL-based and the vendor provides a
# `vendor.gatekeeper_nonsecure` service, so boot does not depend on the HIDL
# IGatekeeper passthrough HAL that is failing here. A13's gatekeeperd is
# HIDL-based and blocks until that HAL registers.
#
# ro.hardware.keymaster=default is the same class of fix for a HAL that
# currently has no .waydroid module; "default" is the conventional name.
_wcfg="${WAYDROID_WORK}/waydroid.cfg"
if [ -f "$_wcfg" ]; then
    for kv in "ro.hardware.gatekeeper=waydroid" "ro.hardware.keymaster=default"; do
        _k="${kv%%=*}"; _v="${kv#*=}"
        if grep -q "^${_k} *=" "$_wcfg"; then
            sed -i "s|^${_k} *=.*|${_k} = ${_v}|" "$_wcfg"
        else
            printf '%s = %s\n' "$_k" "$_v" >> "$_wcfg"
        fi
    done
    gow_log "[hal] ro.hardware.gatekeeper=waydroid / ro.hardware.keymaster=default staged"

    # Section 4c regenerates waydroid_base.prop from waydroid.cfg but runs
    # BEFORE this block, so on a first boot the keys above would not reach the
    # guest until a second session start. Patch the generated file in place as
    # well, and note that 4c's sync check will keep it aligned from now on.
    # NOTE: `ro.input.resampling=0` was tried here and DID NOT FIX the crash.
    # The property is honoured by InputConsumer (verified: `getprop
    # ro.input.resampling` -> 0 in the guest) and it is arguably the right
    # setting for a vsync-aligned synthetic touch device, but the Honor of
    # Kings SIGSEGV reproduced unchanged -- same function, same offset, same
    # ~236s uptime (tombstone_19). Reverted so it does not mask future tests.

    _bprop="${WAYDROID_WORK}/waydroid_base.prop"
    if [ -f "$_bprop" ]; then
        for kv in "ro.hardware.gatekeeper=waydroid" "ro.hardware.keymaster=default"; do
            _k="${kv%%=*}"; _v="${kv#*=}"
            if grep -q "^${_k}=" "$_bprop"; then
                sed -i "s|^${_k}=.*|${_k}=${_v}|" "$_bprop"
            else
                printf '%s=%s\n' "$_k" "$_v" >> "$_bprop"
            fi
        done
        # waydroid.prop is the copy actually bind-mounted into /vendor.
        cp -f "$_bprop" "${WAYDROID_WORK}/waydroid.prop" 2>/dev/null || true
        gow_log "[hal] waydroid_base.prop/waydroid.prop updated in place"
    fi
fi


#########################################
# 4f-bis. Make Android load the real audio HAL, not the stub
#########################################
# Symptom: Android has NO audio at all -- not just games, the whole system.
#
# Android's HAL loader builds the module name as
#     <class>.<instance>.<ro.hardware.<class>.<instance>>.so
# so the primary audio HAL resolves through `ro.hardware.audio.primary`. That
# property is NOT set anywhere in this image (verified: `getprop` returns
# nothing, and no prop file defines it), so the loader gives up and falls back
# to `audio.primary.default.so`.
#
# On this vendor image `audio.primary.default.so` is an empty STUB -- 9800 bytes
# whose only string is its own soname -- while the real implementation lives in
# `audio.primary.waydroid.so` (16840 bytes, exports `audio_hw_primary`, links
# libasound and reads `waydroid.pulse_runtime_path`). Measured consequence:
#
#     AudioFlinger: getMicMute: error -38 getting state from HAL   (ENOSYS)
#     wolf: virtual_sink_<session> IDLE, no sink-inputs ever
#
# Setting `ro.hardware.audio.primary=waydroid` would be the tidy fix, but it
# does not take: appended to waydroid.prop it is ignored even though other
# ro.* lines in the SAME file load fine (other props on lines 20/26/30/70 all
# resolve, only this one does not). Rather than fight the property loader, put
# the real module where the loader already looks.
#
# /vendor is an overlay whose FIRST lowerdir is ${WAYDROID_WORK}/overlay/vendor,
# so a file placed there shadows the image's copy. Copying the waydroid module
# over the `default` name makes the loader find the real implementation under
# whichever name it asks for. Nothing is lost: the shadowed file is a stub.
if [ -d "${WAYDROID_WORK}/rootfs/vendor/lib/hw" ] || \
   [ -f "${WAYDROID_WORK}/images/vendor.img" ]; then
    _ov_vendor="${WAYDROID_WORK}/overlay/vendor"
    _shadowed=0
    for _pair in "lib:lib" "lib64:lib64"; do
        _sd="${_pair%%:*}"; _ld="${_pair##*:}"
        _src="${WAYDROID_WORK}/images/vendor.img"
        _dst_dir="${_ov_vendor}/${_ld}/hw"
        _dst="${_dst_dir}/audio.primary.default.so"

        # Prefer the already-extracted rootfs copy; fall back to reading the
        # module straight out of vendor.img when rootfs is an empty mountpoint
        # (which it is at cont-init time).
        _tmp="$(mktemp 2>/dev/null || echo /tmp/ap.$$)"
        if [ -f "${WAYDROID_WORK}/rootfs/vendor/${_ld}/hw/audio.primary.waydroid.so" ]; then
            cp -f "${WAYDROID_WORK}/rootfs/vendor/${_ld}/hw/audio.primary.waydroid.so" "$_tmp" 2>/dev/null
        elif command -v debugfs >/dev/null 2>&1; then
            debugfs -R "dump /${_ld}/hw/audio.primary.waydroid.so ${_tmp}" "$_src" >/dev/null 2>&1
        fi

        if [ -s "$_tmp" ]; then
            mkdir -p "$_dst_dir" 2>/dev/null
            if cp -f "$_tmp" "$_dst" 2>/dev/null; then
                _shadowed=$((_shadowed+1))
                gow_log "[audio] ${_ld}/hw/audio.primary.default.so <- waydroid impl ($(stat -c %s "$_dst" 2>/dev/null) bytes)"
            fi
        fi
        rm -f "$_tmp" 2>/dev/null
    done
    if [ "$_shadowed" -gt 0 ]; then
        gow_log "[audio] real audio HAL staged over the 'default' stub"
    else
        gow_log "[audio] WARNING: could not stage the real audio HAL; expect no sound"
    fi
fi


#########################################
# 4g-ter. Restore the image's real build type
#########################################
# `waydroid app launch` -- and therefore every game launch through the session
# API -- silently does nothing unless the `cmd` binder service exists. Waydroid
# generates waydroid.prop with "ro.debuggable=0" (helpers/lxc.py, under the
# comment "Added for security reasons") and the spoof sets "ro.build.type=user".
# Those two values make SystemServer SKIP registering the `cmd` service, so the
# `cmd` binary cannot dispatch anything and fails with an unexplained RC=255
# and NO output and NO logcat entry:
#
#     $ am start -a android.settings.SETTINGS
#     RC=255                      # not even the usage text is printed
#     $ service check cmd
#     Service cmd: not found      # while `activity` IS registered
#
# This is not game-specific: launching the built-in Settings app fails the same
# way. The image itself is a userdebug build and says so in its own build.prop:
#
#     rootfs/system/build.prop:
#         ro.build.type=userdebug
#         ro.build.tags=test-keys
#         ro.debuggable=1
#
# so we simply stop overriding it. This weakens the release-keys/tags disguise,
# but no Android game reads ro.build.type to detect spoofing -- they read
# ro.product.*/ro.build.fingerprint, which are left fully spoofed -- whereas
# without this NOTHING can be launched at all.
#
# Note the properties are regenerated on every session start, so they must be
# forced here rather than hand-edited in /data (a manual edit is silently
# reverted by the next `waydroid session start`).
if [ "${WAYDROID_ALLOW_DEBUGGABLE:-1}" != "0" ]; then
    for _pf in "${WAYDROID_WORK}/waydroid_base.prop" "${WAYDROID_WORK}/waydroid.prop"; do
        [ -f "$_pf" ] || continue
        for kv in "ro.build.type=userdebug" "ro.debuggable=1"; do
            _k="${kv%%=*}"; _v="${kv#*=}"
            if grep -q "^${_k}=" "$_pf"; then
                sed -i "s|^${_k}=.*|${_k}=${_v}|" "$_pf"
            else
                printf '%s=%s\n' "$_k" "$_v" >> "$_pf"
            fi
        done
    done
    gow_log "[build] ro.build.type=userdebug, ro.debuggable=1 (required for the 'cmd' service)"

    # The guest caches the generated prop in its own /vendor; if a previous
    # session booted with user/release-keys the stale copy must not win.
    _guest_prop="${WAYDROID_WORK}/rootfs/vendor/waydroid.prop"
    if [ -f "$_guest_prop" ]; then
        for kv in "ro.build.type=userdebug" "ro.debuggable=1"; do
            _k="${kv%%=*}"; _v="${kv#*=}"
            if grep -q "^${_k}=" "$_guest_prop"; then
                sed -i "s|^${_k}=.*|${_k}=${_v}|" "$_guest_prop"
            else
                printf '%s=%s\n' "$_k" "$_v" >> "$_guest_prop"
            fi
        done
        gow_log "[build] guest /vendor/waydroid.prop synced too"
    fi
fi


#########################################
# 4h. libndk MAP_32BIT patch -- DISABLED, DOES NOT WORK
#########################################
# Do not re-enable this without reading the whole note.
#
# Honor of Kings aborts from the UnityMain thread with:
#
#     mmap_posix.cc:128: CHECK failed: 0xffffffffffffffff != 0xffffffffffffffff
#       -> MmapImplOrDie -> ExecRegionAnonymousFactory::Create
#       -> CodePool::Add -> TryLiteTranslateAndInstallRegion
#
# MmapImplOrDie forces the translated-code pool into the low 2GB window via
# MAP_32BIT; tombstones show 197-245 4MB code regions stacked between
# 0x46000000 and 0x7fdfffff, so that window fills up and the next mmap fails.
# It is NOT a RAM shortage -- the host had 19GB free at crash time.
#
# NOP-ing the `or $0x40,%ecx` that adds MAP_32BIT (see
# libndk-nomap32/patch-libndk-map32.py) does make mmap succeed, but it moves
# allocations above 2GB and berberis then refuses them outright. zygote dies at
# startup before any app runs:
#
#     host_code.h:35: CHECK failed: IsInRange<HostCodeAddr>(...)
#       -> CodePool::Add -> InstallEntryTrampoline -> InitHostEntries
#       -> InitBerberis -> native_bridge_initialize
#
# HostCodeAddr is a *narrowed* address type that by design only accepts the low
# window, and InitHostEntries runs unconditionally during native bridge init. So
# the 32-bit window is a hard architectural requirement of this translator, not
# a tunable, and the patched blob must NOT be shipped.
#
# The patched blob and reproducer are kept in libndk-nomap32/ for reference only.
#
# The working fix is a translation-mode change; see section 4i below.
WAYDROID_LIBNDK_PATCH=0


#########################################
# 4i. Force berberis interpret-only mode (fixes HoK code-pool exhaustion)
#########################################
# The low-2GB code-pool window cannot be enlarged (see 4h), so the only lever
# left is to stop burning through it so fast.
#
# Under the stock `two-gear` mode HoK generates translated code relentlessly:
# measured 220+ code regions within 18 seconds of launch, at which point the
# window is full, the next mmap fails, and the game aborts. Every launch died
# the same way, always inside UnityMain.
#
# The upstream vendor build.prop ships:
#
#     ro.berberis.mode=two-gear
#
# berberis also understands `interpret-only`, in which the translator stops
# emitting 4MB executable regions and interprets guest instructions instead.
# The code pool then stops growing.
#
# VERIFIED on this host (game left running, sampled every 15-30s):
#
#     two-gear       18s -> 220 regions -> abort
#     interpret-only 3m33s -> 166 regions (plateaued), game alive and playable
#                    6m58s -> 169 regions, still alive
#
# The trade is interpreter speed. It is the difference between "crashes before
# the login screen" and "runs", so it is the right default here.
#
# HOW IT IS APPLIED
# -----------------
# ro.* properties are read by berberis when the native bridge initialises, i.e.
# when zygote starts. vendor.img is a read-only ext4 image, so build.prop cannot
# be edited in place; it is overridden through Waydroid's vendor overlay:
#
#     /var/lib/waydroid/overlay/vendor/build.prop   (copy of the stock file,
#                                                    with mode swapped)
#     waydroid.cfg:  mount_overlays = True
#
# The stock copy is extracted straight out of vendor.img with debugfs rather
# than read from ${WAYDROID_WORK}/rootfs/vendor: this init script runs BEFORE
# the session mounts the rootfs, so that path does not exist yet.
#
# IMPORTANT: the overlay is mounted when the *session* brings up the rootfs.
# `waydroid container restart` does NOT re-mount it, so a mode change only takes
# effect after a full session restart (i.e. a Moonlight reconnect). Verify with:
#
#     waydroid shell -- getprop ro.berberis.mode
#
# Set WAYDROID_BERBERIS_MODE=two-gear to opt out (game will crash again), or to
# any other mode for experimentation.
_vimg="${WAYDROID_WORK}/images/vendor.img"
_vdst="${WAYDROID_WORK}/overlay/vendor/build.prop"

# Detect the Android release of the installed vendor image. The ro.berberis.*
# knobs only exist in the berberis translator (Android 16+). Android 13 uses the
# older pre-berberis ndk_translation, which reads neither ro.berberis.mode nor
# ro.berberis.flags -- writing them there is harmless but pointless, so skip.
_android_rel=""
if [ -f "$_vimg" ] && command -v debugfs >/dev/null 2>&1; then
    _android_rel="$(debugfs -R "cat build.prop" "$_vimg" 2>/dev/null \
        | sed -n 's/^ro\.vendor\.build\.version\.release=//p' | head -1)"
fi
if [ -z "$_android_rel" ] && [ -f "${WAYDROID_WORK}/rootfs/vendor/build.prop" ]; then
    _android_rel="$(sed -n 's/^ro\.vendor\.build\.version\.release=//p' \
        "${WAYDROID_WORK}/rootfs/vendor/build.prop" 2>/dev/null | head -1)"
fi

if [ "${WAYDROID_BERBERIS_MODE:-interpret-only}" = "two-gear" ]; then
    gow_log "[berberis] mode=two-gear requested; leaving vendor build.prop alone"
elif [ -n "$_android_rel" ] && [ "$_android_rel" -lt 16 ] 2>/dev/null; then
    # Android <= 15: pre-berberis translator. No ro.berberis.* knobs exist.
    # The crash this section works around (code-pool exhaustion) is a berberis
    # defect and is absent here, so there is nothing to tune.
    gow_log "[berberis] Android ${_android_rel} uses ndk_translation (not berberis); skipping mode/flags tuning"
else
    _bmode="${WAYDROID_BERBERIS_MODE:-interpret-only}"

    _stock=""
    if [ -f "$_vimg" ] && command -v debugfs >/dev/null 2>&1; then
        _stock="$(debugfs -R "cat build.prop" "$_vimg" 2>/dev/null)"
    fi
    # Fall back to the mounted rootfs if debugfs is unavailable or failed.
    if [ -z "$_stock" ] && [ -f "${WAYDROID_WORK}/rootfs/vendor/build.prop" ]; then
        _stock="$(cat "${WAYDROID_WORK}/rootfs/vendor/build.prop")"
    fi

    if [ -n "$_stock" ]; then
        mkdir -p "$(dirname "$_vdst")"
        printf '%s\n' "$_stock" \
            | sed "s|^ro\.berberis\.mode=.*|ro.berberis.mode=${_bmode}|" > "$_vdst"
        # Append the key if the stock file did not carry it at all.
        if ! grep -q '^ro\.berberis\.mode=' "$_vdst"; then
            printf 'ro.berberis.mode=%s\n' "$_bmode" >> "$_vdst"
        fi

        # Flags: keep the image's stock set, plus ONE experimental addition.
        # DO NOT "optimise" this without measuring -- one attempt made things far
        # worse.
        #
        # MEASURED RESULT (2026-09-15): dropping disable-link-jumps-between-regions
        # (on the theory that sharing jumps across regions emits less code)
        # backfired badly. Nine consecutive runs crashed in 5s-85s, versus up to
        # 7.5 hours with the stock set. Four crashes landed inside 25 seconds:
        #
        #   _37 09:23:53  21s  221 regions
        #   _38 09:29:51   5s  189
        #   _39 09:30:04  14s  206
        #   _40 09:36:06   5s  188
        #   _41 09:36:16  11s  198
        #   _42 09:36:25   6s  196
        #   _43 09:36:30   5s  190
        #   _44 09:47:50  16s  212
        #   _45 09:49:52  85s  238
        #
        # Mechanism is plausible: with the guard removed, region translation
        # recurses into linked peers instead of stopping, so a single entry point
        # pulls in far more code at once. That in turn suggests the opposite
        # direction: TIGHTENING translation propagation may extend runtime.
        #
        # CURRENT DEFAULT (experimental): stock set + all-jumps-exit-gen-code,
        # which makes every jump end the generated block instead of inlining the
        # target. This ADDS a restriction rather than removing one, so the known
        # protections stay in place and it is trivial to revert:
        #
        #   WAYDROID_BERBERIS_FLAGS=stock     -> image's original flags
        #
        # Baseline to beat (stock flags, interpret-only): game ran 106s+, pool
        # peaked at 173 regions. The regressed run peaked at 188-249 regions in
        # 5-85s.
        #
        # Known flags DIFFER BY IMAGE. The flag-name table is compiled into the
        # binary, so a flag the image does not know is silently ignored (not an
        # error), which means the Android 17 set is simply inert on Android 16.
        #
        # Android 17 (lineage-24.0, libndk 8,743,696 B, BuildId 125abe44...):
        #   accurate-sigsegv, disable-heavy-opts,
        #   disable-adjacent-regions-translation, disable-link-jumps-between-regions,
        #   disable-intrinsic-inlining, disable-link-jumps-within-region,
        #   all-jumps-exit-gen-code, print-code-pool-size
        #
        # Android 16 (lineage-23.2, libndk 5,403,704 B, BuildId 2810e5b4...):
        #   accurate-sigsegv, disable-intrinsic-inlining, interpret-only,
        #   print-code-pool-size, two-gear
        #   (verified by extracting the string table from system.img)
        #
        # So on Android 16 the only usable *restriction* knob besides the mode is
        # disable-intrinsic-inlining. The vendor image already sets
        # accurate-sigsegv, and we add disable-intrinsic-inlining on top.
        if [ "${WAYDROID_BERBERIS_IMAGE:-a16}" = "a17" ]; then
            _bdefault="accurate-sigsegv,disable-heavy-opts,disable-adjacent-regions-translation,disable-link-jumps-between-regions,all-jumps-exit-gen-code"
        else
            _bdefault="accurate-sigsegv,disable-intrinsic-inlining"
        fi
        _bflags="${WAYDROID_BERBERIS_FLAGS:-$_bdefault}"
        [ "$_bflags" = "stock" ] && _bflags=""
        if [ -n "$_bflags" ]; then
            sed -i "s|^ro\.berberis\.flags=.*|ro.berberis.flags=${_bflags}|" "$_vdst"
            if ! grep -q '^ro\.berberis\.flags=' "$_vdst"; then
                printf 'ro.berberis.flags=%s\n' "$_bflags" >> "$_vdst"
            fi
            gow_log "[berberis] flags=${_bflags}"
        fi

        if grep -q '^mount_overlays' "${WAYDROID_WORK}/waydroid.cfg" 2>/dev/null; then
            sed -i 's/^mount_overlays = .*/mount_overlays = True/' "${WAYDROID_WORK}/waydroid.cfg"
        else
            printf 'mount_overlays = True\n' >> "${WAYDROID_WORK}/waydroid.cfg"
        fi
        gow_log "[berberis] mode=${_bmode} staged via vendor overlay (needs session restart)"
    else
        gow_log "[berberis] WARNING: could not read stock build.prop; leaving vendor alone"
    fi
fi

# ---------------------------------------------------------------------------
# mount_overlays = True, ALWAYS -- and OUTSIDE the berberis block above.
# ---------------------------------------------------------------------------
# This used to live inside the `[ -n "$_stock" ]` branch that only berberis
# (Android 16/17) reaches, so on Android 13 it never ran and the setting fell
# back to whatever waydroid inherited: "False".
#
# That single line is the difference between a bootable system and one where
# every ARM64 app dies on launch. With mount_overlays = False the guest mounts
# the bare read-only system.img as /, so the overlay at
# /var/lib/waydroid/overlay (180 files: the whole ndk_translation runtime,
# /system/lib64/arm64/*, the arm64 linker, cpuinfo, ld.config, ...) is NEVER
# applied. Verified on a live boot:
#
#     $ lxc-attach ... ls /system/lib64/arm64/ | wc -l
#     0                                   <- should be 59
#     $ lxc-attach ... ls /system/lib64/libndk_translation.so
#     No such file or directory
#
# and Honor of Kings then dies at startup with:
#
#     java.lang.UnsatisfiedLinkError: dlopen failed:
#       ".../lib/arm64/libtprt.so" is for EM_AARCH64 (183)
#       instead of EM_X86_64 (62)
#         at com.ace.gshell.AceApplication.<clinit>(AceApplication.java:18)
#
# The ABI check fails because the ARM64-only .so is handed straight to the
# x86_64 linker -- there is no translator registered to claim it.
if [ -f "${WAYDROID_WORK}/waydroid.cfg" ]; then
    # -----------------------------------------------------------------------
    # Clear stale rootfs mounts BEFORE asking for the overlay.
    # -----------------------------------------------------------------------
    # Waydroid builds the guest root as:
    #
    #     mount -t overlay -o ro,lowerdir=overlay:rootfs \
    #           overlay /var/lib/waydroid/rootfs
    #
    # and that mount FAILS if anything is already mounted on rootfs. A killed
    # or crashed session leaves exactly that behind:
    #
    #     $ grep waydroid/rootfs /proc/mounts
    #     /dev/loop0 /var/lib/waydroid/rootfs ext4 ro,relatime 0 0
    #
    # Waydroid does not retry -- it treats the failure as "this kernel cannot
    # do overlays" and PERMANENTLY disables the feature:
    #
    #     Mounting overlays failed. The feature has been disabled.
    #     Save config: /var/lib/waydroid/waydroid.cfg     <- now False
    #
    # which costs us the arm64 translator and makes every ARM-only game die
    # with EM_AARCH64 at startup. Unmount the leftovers here so the overlay
    # mount has a clean target. `umount -l` (lazy) because the previous
    # namespace may still hold the mount busy; ordering deepest-first avoids
    # tripping over the nested vendor/waydroid.prop bind.
    _cleared=0
    for _mnt in "${WAYDROID_WORK}/rootfs/vendor/waydroid.prop" \
                "${WAYDROID_WORK}/rootfs/vendor" \
                "${WAYDROID_WORK}/rootfs"; do
        if mountpoint -q "$_mnt" 2>/dev/null; then
            umount -l "$_mnt" 2>/dev/null && _cleared=$((_cleared+1))
        fi
    done
    [ "$_cleared" -gt 0 ] && \
        gow_log "[overlay] cleared ${_cleared} stale rootfs mount(s)"

    if grep -q '^mount_overlays' "${WAYDROID_WORK}/waydroid.cfg" 2>/dev/null; then
        sed -i 's/^mount_overlays = .*/mount_overlays = True/' "${WAYDROID_WORK}/waydroid.cfg"
    else
        printf 'mount_overlays = True\n' >> "${WAYDROID_WORK}/waydroid.cfg"
    fi
    gow_log "[overlay] mount_overlays = True ($(grep '^mount_overlays' "${WAYDROID_WORK}/waydroid.cfg" | tail -1))"

    # The overlay directory itself is what gets mounted over /system. If it is
    # missing or lost its translator payload, no amount of config will help, so
    # say so loudly rather than letting the guest die later with an opaque
    # EM_AARCH64 error.
    _ovl="${WAYDROID_WORK}/overlay"
    if [ -d "$_ovl" ]; then
        _ovl_n="$(find "$_ovl" -type f 2>/dev/null | wc -l)"
        gow_log "[overlay] ${_ovl}: ${_ovl_n} file(s)"
        for _need in "system/lib64/libndk_translation.so" \
                     "system/lib64/arm64/libnative_bridge_vdso.so"; do
            if [ -e "${_ovl}/${_need}" ]; then
                gow_log "[overlay]    ok  ${_need}"
            else
                gow_log "[overlay]    MISSING ${_need} -- ARM64 apps will fail to load"
            fi
        done
    else
        gow_log "[overlay] WARNING: ${_ovl} does not exist; /system overlay unavailable"
    fi
fi


#########################################
# 4i-bis. Force Mesa to pick radeonsi (black-screen fix, part 2)
#########################################
# Background: when an ARM64 app runs through libndk_translation it reaches EGL
# by a different route than native x86_64 processes. Instead of asking minigbm
# for a buffer (which honours gralloc.gbm.device), it takes the legacy
# gralloc0/CrOS path:
#
#     MESA    : Using gralloc0 CrOS API
#     EGL-MAIN: failed to get driver name for fd -1
#     EGL-MAIN: MESA-LOADER: failed to retrieve device information
#
# `fd -1` means Mesa was handed no DRM file descriptor, so it cannot probe the
# GPU to choose a driver. It ends up with no driver at all, the app's surface
# stays black even though minigbm happily allocates correctly sized buffers
# (measured: 1916x1053, stride 7680, RGBA_8888, ~7.9MB each, six of them).
#
# Naming the driver explicitly removes the need to probe at all, and the
# fd -1 / MESA-LOADER errors disappear. This complements the
# `hide_error_dialogs` fix in startup.sh: that one stops the ANR dialog from
# stealing focus during the game's slow start, this one makes sure the renderer
# is actually usable once it gets there.
#
# The variables must reach APPLICATION processes, so they are set on the zygote
# service -- apps are forked from zygote and inherit its environment. Setting
# them in `on early-init` does NOT work (verified: the value never appeared in
# /proc/<zygote>/environ), and lxc.environment in the LXC config does not
# either (init does not forward it into Android).
#
# We therefore shadow /system/etc/init/hw/init.zygote64_32.rc through the
# overlay, which is the same mechanism the translator payload already uses.
if [ "${WAYDROID_MESA_OVERRIDE:-radeonsi}" != "off" ]; then
    _mesa_drv="${WAYDROID_MESA_OVERRIDE:-radeonsi}"
    _zyg_dst_dir="${WAYDROID_WORK}/overlay/system/etc/init/hw"
    _zyg_dst="${_zyg_dst_dir}/init.zygote64_32.rc"

    # The source must come from the system image, NOT from
    # ${WAYDROID_WORK}/rootfs -- at cont-init time rootfs is still an empty
    # mountpoint (it only holds data/, dev/ and run/ until the session mounts
    # system.img over it), so reading from there silently finds nothing:
    #
    #     [mesa] WARNING: .../rootfs/system/etc/init/hw/init.zygote64_32.rc
    #            not found; skipping driver override
    #
    # Read it straight out of the image with debugfs instead. Generate into a
    # temp file first so a failed extraction can never leave a truncated rc
    # behind that would break zygote and therefore the whole boot.
    _zyg_tmp=""
    if command -v debugfs >/dev/null 2>&1; then
        _zyg_tmp="$(mktemp 2>/dev/null || echo /tmp/zygote.rc.$$)"
        if debugfs -R "cat /system/etc/init/hw/init.zygote64_32.rc" \
                "${WAYDROID_WORK}/images/system.img" > "$_zyg_tmp" 2>/dev/null &&
           grep -q '^service zygote ' "$_zyg_tmp"; then
            gow_log "[mesa] read init.zygote64_32.rc from system.img"
        else
            gow_log "[mesa] WARNING: could not read zygote rc from system.img"
            rm -f "$_zyg_tmp"; _zyg_tmp=""
        fi
    else
        gow_log "[mesa] WARNING: debugfs unavailable; cannot patch zygote rc"
    fi

    if [ -n "$_zyg_tmp" ]; then
        mkdir -p "$_zyg_dst_dir" 2>/dev/null
        cp -f "$_zyg_tmp" "$_zyg_dst" 2>/dev/null
        rm -f "$_zyg_tmp" 2>/dev/null

        # Mesa must render on the SAME GPU that gralloc and the display use.
        #
        # §4g writes DRI_PRIME / MESA_VK_DEVICE_SELECT through `lxc.environment`
        # in the LXC config, and that value DOES NOT REACH ANDROID. Verified on
        # a live boot -- SurfaceFlinger and the composer both had no DRI_PRIME
        # at all:
        #
        #     surfaceflinger   DRI_PRIME=0
        #     composer@2.1-se  DRI_PRIME=0
        #
        # With no pinning Mesa probes every render node and picks the first one
        # it likes, which on this host is renderD128 (the RDNA4 discrete card,
        # gfx1200) -- while gralloc.gbm.device pins buffer allocation to
        # renderD129 (the Renoir iGPU, gfx90c). The game then ends up with a GL
        # context on one GPU and its display buffers on the other, and it
        # deadlocks. Measured on Honor of Kings:
        #
        #     libgallium_dri.so  cnd_wait        <- GL threads idle in Mesa
        #     UnityMain          futex_wait       <- waiting for the GL callback
        #     gfxinfo            Total frames: 5  <- 5 frames, then nothing
        #     gl0 utime=0 stime=1                <- zero CPU, never scheduled
        #     fdinfo             drm-pdev: 0000:03:00.0 AND 0000:06:00.0
        #
        # Setting the same pin through the zygote rc reaches every forked app
        # (verified: the game process carries MESA_LOADER_DRIVER_OVERRIDE and
        # GALLIUM_DRIVER when injected this way). `user root` is where
        # per-service setenv lines are legal, same as the Mesa vars above.
        _dri_prime="${WAYDROID_DRI_PRIME:-}"
        if [ -z "$_dri_prime" ]; then
            # Derive from the node section 4g actually settled on, so the
            # renderer and gralloc.gbm.device can never disagree. That section
            # exports WAYDROID_RENDER_NODE_RESOLVED; fall back to renderD129,
            # which is this host's iGPU and the known-good value for A13.
            _dri_node="${WAYDROID_RENDER_NODE_RESOLVED:-${WAYDROID_GRALLOC_DEVICE:-renderD129}}"
            _pci="$(awk -F= '/^PCI_ID=/{print $2}' \
                    "/sys/class/drm/${_dri_node}/device/uevent" 2>/dev/null)"
            [ -n "$_pci" ] && _dri_prime="pci-${_pci%%:*}_${_pci##*:}"
        fi

        # Always rebuilt from the pristine image copy above, so repeated
        # container starts stay idempotent (never 8 setenv lines).
        #
        # WAYDROID_MESA_EXTRA_ENV is a space-separated list of extra VAR=value
        # pairs for experiments (e.g. "MESA_device_select=pci-1002_1638"); each
        # is emitted as its own setenv line on every zygote service.
        if python3 - "$_zyg_dst" "$_mesa_drv" "$_dri_prime" "${WAYDROID_MESA_EXTRA_ENV:-}" <<'PYEOF'
import sys
path, drv, prime, extra = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(path).read().splitlines(True)
out, added = [], 0
for line in lines:
    out.append(line)
    # Every zygote service block starts with "user root"; that is the point
    # where per-service setenv lines are legal.
    if line.strip() == "user root":
        out.append("    setenv MESA_LOADER_DRIVER_OVERRIDE %s\n" % drv)
        out.append("    setenv GALLIUM_DRIVER %s\n" % drv)
        added += 2
        if prime:
            # Same GPU for GL/EGL and for Vulkan; without both, the game can
            # still open its Vulkan context on the other card.
            out.append("    setenv DRI_PRIME %s\n" % prime)
            out.append("    setenv MESA_VK_DEVICE_SELECT %s\n" % prime)
            added += 2
        for pair in extra.split():
            if "=" in pair:
                k, v = pair.split("=", 1)
                out.append("    setenv %s %s\n" % (k, v))
                added += 1
open(path, "w").write("".join(out))
sys.exit(0 if added else 3)
PYEOF
        then
            gow_log "[mesa] zygote overlay: MESA_LOADER_DRIVER_OVERRIDE=${_mesa_drv}"
            if [ -n "$_dri_prime" ]; then
                gow_log "[mesa] zygote overlay: DRI_PRIME=${_dri_prime} (keeps GL on the gralloc GPU)"
            else
                gow_log "[mesa] WARNING: no DRI_PRIME derived; GL may pick the other GPU"
            fi
        else
            gow_log "[mesa] WARNING: could not inject setenv into zygote rc"
            rm -f "$_zyg_dst" 2>/dev/null
        fi
    fi
fi


#########################################
# 4i-ter. Give hwcomposer a usable Wayland display (black-screen fix, part 3)
#########################################
# Without this the guest cannot open a display at all, and the visible symptom
# is exactly "splash screen, then black":
#
#     hwcomposer: WAYLAND_DISPLAY: wayland-0
#     hwcomposer: XDG_RUNTIME_DIR: /run/user/1000
#     hwcomposer: Couldnt open Wayland display.
#     hwcomposer: failed to open wayland connection
#     android.hardware.graphics.composer@2.1-service:
#         failed to open hwcomposer device: No such device
#
# hwcomposer falls back to those two compiled defaults because NOTHING in its
# environment sets them. Measured on a live guest:
#
#     $ tr '\0' '\n' < /proc/<surfaceflinger>/environ | grep -E 'XDG|WAYLAND'
#     (no output at all)
#
# With no composer, SurfaceFlinger never starts either, so Android hangs in
# bring-up and the framebuffer keeps whatever the boot animation last drew.
#
# The values must be the GUEST-side paths. Waydroid bind-mounts the host
# compositor socket into the container as /run/xdg/wayland-0 (see
# lxc.mount.entry in the generated config_session), so:
#
#     XDG_RUNTIME_DIR=/run/xdg
#     WAYLAND_DISPLAY=wayland-0
#
# NOT the host's /run/user/wolf + wayland-N.
#
# Android init merges every .rc it loads, and re-declaring an existing
# `service` name ADDS to that service rather than replacing it, so a small
# extra file in the vendor overlay is enough to inject the two setenv lines.
if [ "${WAYDROID_HWC_WAYLAND:-1}" != "0" ]; then
    _hwc_dir="${WAYDROID_WORK}/overlay/vendor/etc/init"
    _hwc_rc="${_hwc_dir}/zz-waydroid-wayland.rc"
    _hwc_guest_xdg="${WAYDROID_HWC_XDG_RUNTIME_DIR:-/run/xdg}"
    _hwc_guest_disp="${WAYDROID_HWC_WAYLAND_DISPLAY:-wayland-0}"

    if mkdir -p "$_hwc_dir" 2>/dev/null; then
        cat > "$_hwc_rc" <<HWCEOF
# Managed by gow-waydroid startup.sh -- do not edit.
#
# hwcomposer has no XDG_RUNTIME_DIR/WAYLAND_DISPLAY in its environment, so it
# falls back to wayland-0 under /run/user/1000 and cannot find the compositor.
# These are the guest-side values; the host socket is bind-mounted to
# /run/xdg/wayland-0 by the generated LXC config_session.
service vendor.hwcomposer-2-1 /vendor/bin/hw/android.hardware.graphics.composer@2.1-service
    setenv XDG_RUNTIME_DIR ${_hwc_guest_xdg}
    setenv WAYLAND_DISPLAY ${_hwc_guest_disp}
HWCEOF
        if [ -s "$_hwc_rc" ]; then
            gow_log "[hwc] wayland env overlay: XDG_RUNTIME_DIR=${_hwc_guest_xdg} WAYLAND_DISPLAY=${_hwc_guest_disp}"
        else
            gow_log "[hwc] WARNING: could not write ${_hwc_rc}"
        fi
    else
        gow_log "[hwc] WARNING: could not create ${_hwc_dir}"
    fi
fi



#########################################
# 5. Android system image
#########################################
# `waydroid init` downloads the LineageOS system + vendor images (~1.5GB).
#
# This runs HERE, as root, for two independent reasons:
#   a) waydroid hard-refuses otherwise -- tools/__init__.py does
#      `if os.geteuid() != 0: raise RuntimeError('Action "init" needs root
#      access')`. Verified against waydroid 1.6.2 in this very image.
#   b) it writes into /var/lib/waydroid, which stage 4/6 owns as root.
#
# IMPORTANT: this is OFF by default.
#
# An earlier revision did the download unconditionally here, which meant
# *every* `docker run` blocked for the length of an 838MB download -- not
# just the real session, but also `bin/test-image.sh`'s smoke layers and any
# one-off diagnostic command. That would have broken CI outright, since
# Layer 2 runs init scripts as root and has a 60s timeout.
#
# So the default is now lazy: the download is triggered by scripts/startup.sh
# (the actual session path, which has no timeout) unless the operator opts in
# either by passing WAYDROID_INIT_ON_START=1 or by baking at build time with
# BAKE_ANDROID_IMAGE=true.
#
# BUT startup.sh runs as `retro`, and `waydroid init` requires root. So the
# eager path here is: a non-root marker file is left by startup.sh requesting
# the download, and this stage performs it on the NEXT start as root. In
# practice the reliable flow is the build-time bake or the documented
# `waydroid-setup.sh init` run; this branch exists so the marker is honoured
# rather than silently ignored.
WAYDROID_WORK="${WAYDROID_WORK:-/var/lib/waydroid}"
INIT_REQUEST_MARKER="${WAYDROID_WORK}/.init-requested"

# "Initialised" means waydroid.cfg + rootfs/, per waydroid's own
# initializer.is_initialized(). Checking only images/system.img is wrong and
# produced a black screen: a partial download leaves system.img present but
# rootfs/ missing, so waydroid still refuses to start while our check said
# everything was fine.
if [ -f "${WAYDROID_WORK}/waydroid.cfg" ] && [ -d "${WAYDROID_WORK}/rootfs" ]; then
    gow_log "[waydroid] Waydroid is initialised (${WAYDROID_WORK})"
elif [ "${WAYDROID_SKIP_INIT:-0}" = "1" ]; then
    gow_log "[waydroid] Skipping 'waydroid init' (WAYDROID_SKIP_INIT=1)"
elif [ "${WAYDROID_INIT_ON_START:-0}" = "1" ] || [ -f "$INIT_REQUEST_MARKER" ]; then
    gow_log "[waydroid] Initialising Android images (this downloads ~1.5GB)"
    # Flag is -s/--system_type, NOT -t: `waydroid init -t VANILLA` fails
    # with "unrecognized arguments: -t" on 1.6.2.
    if waydroid init -s "${WAYDROID_IMAGE_TYPE:-VANILLA}"; then
        gow_log "[waydroid] Android image initialised"
        rm -f "$INIT_REQUEST_MARKER"
    else
        gow_log "[waydroid] WARNING: 'waydroid init' failed (check outbound network)"
        gow_log "[waydroid]    The session will still start; Android will report"
        gow_log "[waydroid]    'not initialized' until the images exist."
    fi
else
    gow_log "[waydroid] Android images not present; skipping download on start"
    gow_log "[waydroid]    Enable with WAYDROID_INIT_ON_START=1, or bake them with"
    gow_log "[waydroid]    --build-arg BAKE_ANDROID_IMAGE=true, or run:"
    gow_log "[waydroid]      waydroid-setup.sh init"
fi

#########################################
# 6. Container manager
#########################################
# Started HERE because `waydroid container start` requires root:
#     ERROR: Action "container" needs root access
#
# Waydroid normally runs this as ExecStart of waydroid-container.service, with
# dbus/id.waydro.Container.conf providing D-Bus activation. There is no
# systemd in this container, so we start it ourselves -- exactly as the unit
# would -- and background it. It then lives for the life of the container and
# owns the D-Bus name id.waydro.Container, which scripts/startup.sh (running
# as uid 1000) uses to detect readiness.
#
# Not fatal if it fails: the logs are kept so startup.sh can surface them,
# and the reason is usually visible there (missing binder, missing rootfs).
if [ -x /usr/bin/waydroid ]; then
    gow_log "[container] Starting Waydroid container manager"
    # shellcheck disable=SC2024  # root writes /tmp, this is intentional
    nohup waydroid container start >/tmp/waydroid-container.log 2>&1 &

    manager_up=""
    for _ in $(seq 1 30); do
        if dbus-send --system --dest=org.freedesktop.DBus --type=method_call \
                --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames \
                2>/dev/null | grep -q '"id.waydro.Container"'; then
            manager_up=1
            break
        fi
        sleep 1
    done

    if [ -n "$manager_up" ]; then
        gow_log "[container] Manager is up (id.waydro.Container registered)"
    else
        gow_log "[container] WARNING: manager did not come up within 30s"
        sed 's/^/      /' /tmp/waydroid-container.log 2>/dev/null | tail -10
    fi
else
    gow_log "[container] waydroid binary not found; skipping manager start"
fi

#########################################
# 4j. Optional: switch the ARM translator to Intel Houdini
#########################################
# OFF BY DEFAULT. Enable with WAYDROID_ARM_TRANSLATOR=libhoudini.
#
# The default translator is Google's libndk_translation 0.2.3, which is what
# the waydro.id Android 13 image ships and what every working feature in this
# project was validated against (rendering, audio, online mode). Nothing below
# runs unless explicitly opted in, so the default is untouched.
#
# Why the escape hatch exists: Honor of Kings dies with SIGSEGV roughly 155s
# into every match -- seven tombstones, all in libinput's InputConsumer
# (hasPendingBatch / consumeSamples at function offset +0), with `this` sitting
# in the scudo heap. The game's anti-cheat (libtersafe/libptr loaded) scans
# memory periodically during a match, and under binary translation that is the
# prime suspect for corrupting unrelated framework heap.
#
# Switching translator is the community's standard mitigation for exactly this
# class of ARM-game crash under Waydroid:
#   waydroid#702 "Most games don't work"
#   b-log.to/tech-analysis/waydroid-arm-translator-fix
# libndk is reportedly faster on AMD, which is why it stays the default here.
#
# CAVEAT worth knowing before enabling: libndk reaches EGL through its own
# proxy libraries (libndk_translation_proxy_libEGL.so, _libGLESv2.so, ... in
# the overlay). Houdini does not use those, so graphics goes through a
# different path. Expect to re-verify rendering, audio and online mode after
# switching.
if [ "${WAYDROID_ARM_TRANSLATOR:-libndk}" = "libhoudini" ]; then
    _hz="/opt/gow/houdini/libhoudini.zip"
    _ovs="${WAYDROID_WORK}/overlay/system"
    _hmarker="${_ovs}/etc/init/houdini.rc"

    if [ ! -f "$_hmarker" ]; then
        if [ -f "$_hz" ]; then
            mkdir -p "$_ovs" 2>/dev/null
            # Extract only prebuilts/* -- that subtree is the /system content
            # (bin/, etc/, lib/, lib64/). Written into the overlay so it lands
            # in the guest without touching the read-only system image, and it
            # persists on the data volume, so this runs once.
            _hn="$(python3 - "$_hz" "$_ovs" <<'PYEOF' 2>/dev/null
import sys, zipfile, os
z = zipfile.ZipFile(sys.argv[1]); dst = sys.argv[2]; n = 0
for m in z.namelist():
    if '/prebuilts/' not in m or m.endswith('/'):
        continue
    out = os.path.join(dst, m.split('/prebuilts/', 1)[1])
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with z.open(m) as f, open(out, 'wb') as g:
        g.write(f.read())
    n += 1
print(n)
PYEOF
)"
            if [ -n "$_hn" ] && [ "$_hn" -gt 0 ] 2>/dev/null; then
                chmod 0755 "${_ovs}/bin/houdini" "${_ovs}/bin/houdini64" 2>/dev/null
                gow_log "[arm] libhoudini extracted into overlay (${_hn} files)"
            else
                gow_log "[arm] WARNING: libhoudini extraction produced nothing"
            fi
        else
            gow_log "[arm] WARNING: ${_hz} missing; cannot switch translator"
        fi
    else
        gow_log "[arm] libhoudini already staged in overlay"
    fi

    # Point the native bridge at Houdini. Houdini's own binfmt registration
    # lives in etc/init/houdini.rc, which was extracted above and is picked up
    # because Android's init merges every .rc under /system/etc/init.
    if [ -f "${WAYDROID_WORK}/waydroid.cfg" ]; then
        if grep -q '^ro\.dalvik\.vm\.native\.bridge' "${WAYDROID_WORK}/waydroid.cfg"; then
            sed -i 's|^ro\.dalvik\.vm\.native\.bridge *=.*|ro.dalvik.vm.native.bridge = libhoudini.so|' \
                "${WAYDROID_WORK}/waydroid.cfg"
        else
            printf 'ro.dalvik.vm.native.bridge = libhoudini.so\n' >> "${WAYDROID_WORK}/waydroid.cfg"
        fi
    fi
    for _p in "${WAYDROID_WORK}/waydroid_base.prop" "${WAYDROID_WORK}/waydroid.prop"; do
        [ -f "$_p" ] || continue
        if grep -q '^ro\.dalvik\.vm\.native\.bridge=' "$_p"; then
            sed -i 's|^ro\.dalvik\.vm\.native\.bridge=.*|ro.dalvik.vm.native.bridge=libhoudini.so|' "$_p"
        else
            printf 'ro.dalvik.vm.native.bridge=libhoudini.so\n' >> "$_p"
        fi
    done
    gow_log "[arm] translator: libhoudini (ro.dalvik.vm.native.bridge=libhoudini.so)"
else
    gow_log "[arm] translator: libndk_translation (default; WAYDROID_ARM_TRANSLATOR=libhoudini to switch)"
fi

#########################################
# 7. Hand ownership to the session user
#########################################
# startup.sh runs as ${UNAME} and must be able to read the images and write
# session state, so do this last, after 'waydroid init' has created its
# files as root.
if [ "${UNAME}" != "root" ]; then
    chown -R "${UNAME}:${UNAME}" /var/lib/waydroid /run/waydroid-lxc 2>/dev/null || \
        gow_log "[setup] WARNING: could not chown Waydroid state dirs"
fi

gow_log "**** Waydroid runtime setup DONE ****"
