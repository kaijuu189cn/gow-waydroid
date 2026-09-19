#!/bin/bash
# Create and normalise the runtime directory before anything else needs it.
#
# WHY THIS IS NUMBERED 06 (before the base image's 10-setup_user.sh)
# -----------------------------------------------------------------
# /etc/cont-init.d/*.sh are sourced in ALPHABETICAL order. The base image's
# 10-setup_user.sh ends with:
#
#     gow_log "Ensure XDG_RUNTIME_DIR is writable"
#     chown -R "${PUID}:${PGID}" "${XDG_RUNTIME_DIR}"
#
# under `set -e`, and gow's base-app Dockerfile sets
# XDG_RUNTIME_DIR=/tmp/.X11-unix without ever creating that directory. The
# chown therefore failed:
#
#     chown: cannot access '/tmp/.X11-unix': No such file or directory
#
# and `set -e` aborted the ENTIRE init sequence there -- 15-setup_devices,
# 20-waydroid-setup, 30-nvidia and init-gamescope never ran at all. The
# container came up with no binderfs, no D-Bus, no network and no session.
#
# WHY THE DIRECTORY MATTERS AT ALL
# --------------------------------
# XDG_RUNTIME_DIR is where sway creates its IPC socket ($SWAYSOCK), its
# Wayland display (wayland-N), and where Xwayland puts its X11 sockets. If it
# is missing or not writable by the session user:
#   * sway cannot publish its IPC socket
#   * waybar (spawned by sway via `bar { swaybar_command waybar }`) cannot
#     connect and retries in a tight loop, flooding the log with
#     "[error] Workspaces: Unable to receive IPC header"
#   * Xwayland refuses the directory: "/tmp/.X11-unix not owned by root or us"
#
# NOTE: this script only prepares the filesystem. Deciding which wlroots
# backend sway should use must happen in /opt/gow/startup.sh, because that
# runs as a *separate* process via `gosu` and does not inherit exports from
# here.
set -e

source /opt/gow/bash-lib/utils.sh

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/.X11-unix}"

if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    gow_log "[runtime] Creating $XDG_RUNTIME_DIR"
    mkdir -p "$XDG_RUNTIME_DIR"
fi

# IMPORTANT: do NOT chown XDG_RUNTIME_DIR here.
#
# Under Wolf, XDG_RUNTIME_DIR is /run/user/wolf, a BIND MOUNT of the host's
# /data/stacks/wolf/run-user-wolf -- a directory SHARED with the Wolf server
# container itself. Chowning it from this container (uid 1000) propagates to
# the host path and re-owns it, which then breaks Wolf's own root PulseAudio
# daemon:
#
#     XDG_RUNTIME_DIR (/run/user/wolf) is not owned by us (uid 0), but by uid 1000!
#     pulseaudio: Failed to acquire autospawn lock
#
# and Wolf's pulseaudio enters FATAL state, which in turn prevents the
# Android session from ever being streamed. The directory is owned and
# writable by whatever Wolf decides; this container must leave it alone.
#
# (A previous revision did `chown ${PUID}:${PGID}` here and corrupted the
# shared directory. See apps/waydroid history.)

# 0700 per the XDG spec is also wrong for a shared dir: changing the mode of
# a shared host directory would break the sibling Wolf container. Leave both
# ownership and mode untouched when the directory already exists; only apply
# them when we genuinely created it ourselves above.
if [ ! -d "$XDG_RUNTIME_DIR/sway.socket" ]; then
    # sway needs to be able to create its socket. Since we must not chown the
    # shared directory, verify it is writable instead and say so clearly.
    if [ -w "$XDG_RUNTIME_DIR" ]; then
        gow_log "[runtime] XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR is writable (owner $(stat -c '%U' "$XDG_RUNTIME_DIR" 2>/dev/null || echo '?'))"
    else
        gow_log "[runtime] WARNING: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR is NOT writable by us"
        gow_log "[runtime]    owner=$(stat -c '%U:%G' "$XDG_RUNTIME_DIR" 2>/dev/null) mode=$(stat -c '%a' "$XDG_RUNTIME_DIR" 2>/dev/null)"
        gow_log "[runtime]    sway may be unable to create its IPC socket here."
    fi
fi

gow_log "[runtime] XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR ready (owner $(stat -c '%U' "$XDG_RUNTIME_DIR" 2>/dev/null || echo '?'))"

# ---------------------------------------------------------------------------
# /run/xdg -- the Android container's XDG runtime dir
# ---------------------------------------------------------------------------
# Waydroid's session config (lxc/waydroid/config_session) contains:
#
#     lxc.mount.entry = tmpfs /run/xdg none create=dir 0 0
#
# LXC applies `create=dir` to the destination *inside* the new rootfs, not to
# the host-side target. So if /run/xdg does not already exist on the host
# side, the tmpfs mount fails with a misleading error:
#
#     Failed to mount "tmpfs" on "/run/xdg": No such device
#     Failed to setup mount entries
#     OSError: container failed to start
#
# which shows up as a black screen with no obvious cause. Creating the
# directory here makes the mount succeed. Verified: with /run/xdg present,
# `mount -t tmpfs tmpfs /run/xdg` works; without it, LXC aborts.
if [ ! -d /run/xdg ]; then
    gow_log "[runtime] Creating /run/xdg (Android container runtime dir)"
    mkdir -p /run/xdg
fi
chmod 0755 /run/xdg 2>/dev/null || true

# The session config also bind-mounts the parent Wayland socket to
# /run/xdg/wayland-0 inside the container, and the PulseAudio socket to
# /run/xdg/pulse/native. LXC creates those leaf paths itself (create=file),
# but the intermediate pulse directory must exist.
mkdir -p /run/xdg/pulse 2>/dev/null || true

# ---------------------------------------------------------------------------
# LXC staging rootfs
# ---------------------------------------------------------------------------
# liblxc stages the container rootfs at /usr/lib/<triplet>/lxc/rootfs inside a
# private mount namespace. Its README states the directory "must exist, even
# though it may be empty".
#
# Waydroid's generated config sets `lxc.autodev = 0` and then uses relative
# mount entries such as `lxc.mount.entry = tmpfs dev tmpfs nosuid 0 0`
# (see lxc/waydroid/config_nodes). With autodev disabled LXC does NOT create
# the staging `dev/` itself, and the mount fails:
#
#     Failed to mount "tmpfs" on "/usr/lib/x86_64-linux-gnu/lxc/rootfs/dev"
#     No such file or directory
#
# Isolated with a minimal 5-line LXC config: identical settings succeed with
# autodev at its default (1) and fail with `autodev = 0`, so this is an
# interaction between Waydroid's config and containerised LXC rather than a
# missing directory in the image.
#
# Creating it here does not help, because LXC rebuilds the staging tree in
# its own namespace; it is kept only so the directory exists for the
# README's requirement.
for _lxc_rootfs in /usr/lib/*/lxc/rootfs; do
    [ -d "$_lxc_rootfs" ] || continue
    mkdir -p "${_lxc_rootfs}" 2>/dev/null || true
done
