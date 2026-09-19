#!/bin/bash
# Create XDG_RUNTIME_DIR before anything else runs.
#
# WHY THIS IS NUMBERED 05 AND NOT PART OF 20-waydroid-setup.sh
# -----------------------------------------------------------
# /etc/cont-init.d/*.sh are sourced in ALPHABETICAL order. The base image's
# 10-setup_user.sh ends with:
#
#     gow_log "Ensure XDG_RUNTIME_DIR is writable"
#     chown -R "${PUID}:${PGID}" "${XDG_RUNTIME_DIR}"
#
# under `set -e`. gow's base-app Dockerfile sets
# XDG_RUNTIME_DIR=/tmp/.X11-unix but nothing ever creates that directory, so
# that chown fails:
#
#     chown: cannot access '/tmp/.X11-unix': No such file or directory
#
# and because of `set -e` the whole init sequence aborts right there -- 15-,
# 20-, 30-nvidia and init-gamescope never run. The container comes up with no
# binderfs, no D-Bus, no network and no session.
#
# Creating the directory here (05 < 10) fixes the root cause rather than
# working around the symptom.
#
# Consequences if it is missing, even when init does continue:
#   * sway cannot create $SWAYSOCK ($XDG_RUNTIME_DIR/sway.socket)
#   * waybar, which sway spawns as its status bar, then floods the log with
#     "[error] Workspaces: Unable to receive IPC header" (hundreds of lines)
#   * Waydroid is a Wayland client and needs WAYLAND_DISPLAY, which sway
#     publishes via this runtime dir
set -e

source /opt/gow/bash-lib/utils.sh

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/.X11-unix}"

# Only create the directory if it is missing. Crucially, when it already
# exists it is very likely a BIND MOUNT of a directory shared with the Wolf
# server container (Wolf sets XDG_RUNTIME_DIR=/run/user/wolf, backed by
# /data/stacks/wolf/run-user-wolf). We must NOT chown or chmod a shared
# host directory from here:
#
#   * chown would re-own the host path to uid 1000, breaking Wolf's root
#     PulseAudio ("XDG_RUNTIME_DIR ... not owned by us (uid 0)"), which then
#     goes FATAL and the Android session is never streamed.
#   * chmod 700 would change the mode of the shared dir and lock out the
#     sibling Wolf process.
#
# The only case where we may set ownership/mode is when this script itself
# just created the directory (i.e. it was not present, so it is not shared).
_created_here=0
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    gow_log "[runtime] Creating $XDG_RUNTIME_DIR"
    mkdir -p "$XDG_RUNTIME_DIR"
    _created_here=1
fi

if [ "$_created_here" = "1" ]; then
    # 0700 per the XDG spec, and owned by the session user, only because we
    # own this directory. 10-setup_user.sh will chown it to ${PUID}:${PGID}
    # right after us anyway.
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
    if [ "${UNAME:-retro}" != "root" ]; then
        chown "${PUID:-1000}:${PGID:-1000}" "$XDG_RUNTIME_DIR" 2>/dev/null || true
    fi
else
    gow_log "[runtime] XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR already exists (shared; leaving owner $(stat -c '%U:%G' "$XDG_RUNTIME_DIR" 2>/dev/null) untouched)"
fi

gow_log "[runtime] XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR ready"
