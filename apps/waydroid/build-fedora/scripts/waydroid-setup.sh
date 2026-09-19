#!/bin/bash
# One-shot / diagnostic helper for the Waydroid image.
#
# Exists so users can debug a streamed session that shows a black screen
# without having to remember Waydroid's internals. Invoked as
# `/opt/gow/waydroid-setup.sh <command>`.
#
#   status     show binder, image and container state
#   init       (re)download the Android images
#   net-start  bring up the bridge + NAT only
#   net-stop   tear the bridge down
set -e

source /opt/gow/bash-lib/utils.sh

CMD="${1:-status}"

show_binder() {
    if [ -e /dev/binderfs/binder-control ]; then
        gow_log "binderfs: mounted at /dev/binderfs"
        ls /dev/binderfs/ | sed 's/^/    /'
    elif [ -e /dev/binder ]; then
        gow_log "binder:   legacy node /dev/binder present"
    else
        gow_log "binder:   MISSING - Android will not start"
    fi
    [ -e /dev/ashmem ] && gow_log "ashmem:   /dev/ashmem present" \
                       || gow_log "ashmem:   absent (fine on kernel >= 5.18)"
}

show_images() {
    local img="${WAYDROID_WORK:-/var/lib/waydroid}"
    # Match waydroid's own definition of "initialised"
    # (initializer.is_initialized): config file AND rootfs directory.
    local cfg_ok=0 rootfs_ok=0
    [ -f "$img/waydroid.cfg" ] && cfg_ok=1
    [ -d "$img/rootfs" ] && rootfs_ok=1

    if [ "$cfg_ok" = 1 ] && [ "$rootfs_ok" = 1 ]; then
        gow_log "images:   initialised under $img"
        du -sh "$img" 2>/dev/null | sed 's/^/    /' || true
    else
        gow_log "images:   NOT initialised (run: $0 init)"
        [ "$cfg_ok" = 1 ] || gow_log "    missing: $img/waydroid.cfg"
        [ "$rootfs_ok" = 1 ] || gow_log "    missing: $img/rootfs/"
        # A present-but-unusable system.img is the signature of an
        # interrupted download, which is the most common cause.
        if [ -f "$img/images/system.img" ]; then
            gow_log "    note: images/system.img exists ($(stat -c%s "$img/images/system.img" 2>/dev/null) bytes)"
            gow_log "          but the install is incomplete -> re-run '$0 init' with -f"
        fi
    fi
}

show_container() {
    # There is no `waydroid container status` subcommand (only
    # start|stop|restart|freeze|unfreeze). The manager's presence is
    # signalled by the D-Bus name from its systemd unit: BusName=id.waydro.Container.
    if dbus-send --system --dest=org.freedesktop.DBus --type=method_call \
            --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames \
            2>/dev/null | grep -q '"id.waydro.Container"'; then
        gow_log "container: running (id.waydro.Container is on the bus)"
    else
        gow_log "container: not running"
    fi
}

show_gpu() {
    # Waydroid renders Android through the host GPU. The classic failure is
    # `amdgpu: amdgpu_cs_ctx_create2 failed. (-13)` (-13 = EACCES): the
    # session user is not in the group that owns /dev/dri/cardN.
    #
    # GOW solves this with GOW_REQUIRED_DEVICES + ensure-groups, which chgrp's
    # the device and adds the user to a matching synthetic group. If that env
    # var is not passed, the session runs without GPU access and the compositor
    # fails exactly this way.
    local user="${UNAME:-retro}"
    local ugroups
    ugroups="$(id -G "$user" 2>/dev/null)" || ugroups=""
    local missing=""
    for d in /dev/dri/card* /dev/dri/renderD*; do
        [ -e "$d" ] || continue
        local gid mode
        gid="$(stat -c %g "$d")"
        mode="$(stat -c %a "$d")"
        # world-readable is fine; otherwise the group must match
        case "$mode" in
            *[4567]) continue ;;   # last digit >= 4 -> others can rw
        esac
        if ! echo " $ugroups " | grep -q " $gid "; then
            missing="$missing $(basename "$d")(gid=$gid)"
        fi
    done

    if [ -z "$missing" ]; then
        gow_log "gpu:      $user has access to all /dev/dri nodes"
    else
        gow_log "gpu:      $user CANNOT access:$missing"
        gow_log "          -> amdgpu_cs_ctx_create2 failed (-13) / black screen"
        gow_log "          Fix: pass GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
        gow_log "          (the shipped wolf.config.toml already does this)"
    fi

    # Acceleration mode: Waydroid's getDriNode() walks /dev/dri/renderD* and,
    # for any node whose kernel driver is not in its "unsupported" list
    # (nvidia), selects gralloc=gbm + egl=mesa (hardware acceleration).
    # With no usable render node it falls back to gralloc=default +
    # egl=swiftshader (software rendering). Mirror that probe here so the
    # operator can tell at a glance whether the GPU is actually engaged.
    local render="" driver=""
    for n in /dev/dri/renderD*; do
        [ -e "$n" ] || continue
        driver="$(sed -n 's/^DRIVER=//p' "/sys/class/drm/$(basename "$n")/device/uevent" 2>/dev/null)"
        case "$driver" in
            ""|nvidia) continue ;;   # nvidia is explicitly unsupported upstream
        esac
        render="$n"
        break
    done

    if [ -n "$render" ]; then
        gow_log "gpu:      HARDWARE acceleration (gralloc=gbm egl=mesa) via $render (driver=$driver)"
        # The card node paired with the render node is what Android opens for
        # display scanout; flag it if no card node is visible at all. We match
        # /dev/dri/card* directly (the nodes actually passed into the
        # container) rather than walking sysfs, because /sys/class/drm's
        # card* entries are directories and `ls` lists their CONTENTS
        # (card1-DP-1, dev, power, ...) instead of the node name itself.
        local card=""
        card="$(ls -d /dev/dri/card* 2>/dev/null | head -1)"
        if [ -n "$card" ]; then
            gow_log "          card node visible: $card (display scanout available)"
        else
            gow_log "          note: no /dev/dri/card* visible (GPU render still works via renderD*)"
        fi
    else
        gow_log "gpu:      SOFTWARE rendering (gralloc=default egl=swiftshader) -- no usable /dev/dri/renderD*"
        gow_log "          For hardware acceleration ensure /dev/dri/* is passed and"
        gow_log "          DeviceCgroupRules allows 'c 226:* rmw' (drm major)."
    fi
}

case "$CMD" in
    status)
        show_binder
        show_images
        show_container
        show_gpu
        ;;
    init)
        # -f forces a clean re-initialisation. Needed when a previous
        # download was interrupted: waydroid otherwise sees a partial
        # system.img and may refuse or produce an unbootable install.
        gow_log "Downloading Android images (~1.5GB), forcing re-init..."
        if waydroid init -f -s "${WAYDROID_IMAGE_TYPE:-VANILLA}"; then
            rm -f "${WAYDROID_WORK:-/var/lib/waydroid}/.init-requested"
            gow_log "Done. Verify with: $0 status"
        else
            gow_log "FAILED. Check outbound network access."
            exit 1
        fi
        ;;
    net-start)
        /opt/gow/waydroid-net.sh start
        ;;
    net-stop)
        /opt/gow/waydroid-net.sh stop
        ;;
    *)
        gow_log "usage: $0 status|init|net-start|net-stop"
        exit 1
        ;;
esac
