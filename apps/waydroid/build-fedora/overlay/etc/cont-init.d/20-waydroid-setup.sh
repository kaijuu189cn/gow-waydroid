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
        # Prefer what Waydroid already wrote into the config.
        chosen="$(awk '/^lxc\.mount\.entry = .*\/dev\/dri\/renderD[0-9]+ /{print $4}' "$cfg" | head -1)"
        chosen="$(basename "${chosen:-}")"
        [ -n "$chosen" ] && chosen="/dev/dri/$chosen"
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

    gow_log "[dri] Multiple DRM devices present; pinning Android to ${rname} ($(basename "${chosen_card:-none}"))"
}

_waydroid_pin_single_gpu "${WAYDROID_WORK}/lxc/waydroid/config_nodes"


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
