#!/bin/bash
# Restore the ownership of a shared XDG_RUNTIME_DIR.
#
# WHY THIS EXISTS (and must run AFTER 10-setup_user.sh)
# -----------------------------------------------------
# Under Wolf, XDG_RUNTIME_DIR is /run/user/wolf, which is a BIND MOUNT of the
# host directory /data/stacks/wolf/run-user-wolf -- SHARED between this
# container and the Wolf server container itself.
#
# The base image's 10-setup_user.sh does:
#
#     chown -R "${PUID}:${PGID}" "${XDG_RUNTIME_DIR}"   # PUID=1000
#
# which re-owns the shared host directory to uid 1000. That breaks Wolf's
# root PulseAudio daemon:
#
#     XDG_RUNTIME_DIR (/run/user/wolf) is not owned by us (uid 0), but by uid 1000!
#     pulseaudio: Failed to acquire autospawn lock
#     (then) gave up: pulseaudio entered FATAL state
#
# and, because Wolf waits for the pulse socket before serving, the Android
# session is never streamed -- the Moonlight client shows only the desktop,
# never Waydroid.
#
# This script runs at priority 25 (after 10), detects the shared-directory
# situation, and restores root ownership so the Wolf sibling process keeps
# working. It only acts when XDG_RUNTIME_DIR is NOT the private
# /tmp/.X11-unix fallback (i.e. it is the Wolf-provided shared path).
#
# NOTE: this does NOT chmod; only ownership is corrected, because the mode of
# a shared dir is Wolf's to decide.
set -e

source /opt/gow/bash-lib/utils.sh

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/.X11-unix}"

# Only the shared, Wolf-provided path is dangerous to leave chowned to 1000.
# The private fallback /tmp/.X11-unix is ours and should stay 1000.
case "$XDG_RUNTIME_DIR" in
    /tmp/.X11-unix|/tmp)
        gow_log "[restore] XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR is private; leaving ownership as-is"
        return 0
        ;;
esac

# It is (or was) a shared host bind. Restore root ownership, which is what
# Wolf expects. Only act if the current owner is NOT already root, to avoid
# churning on every start.
_owner="$(stat -c '%u:%g' "$XDG_RUNTIME_DIR" 2>/dev/null || echo '?')"
if [ "$_owner" = "0:0" ]; then
    gow_log "[restore] $XDG_RUNTIME_DIR already root-owned; nothing to do"
    return 0
fi

gow_log "[restore] $XDG_RUNTIME_DIR is owned by ${_owner}; restoring to root (shared with Wolf)"
chown 0:0 "$XDG_RUNTIME_DIR" 2>/dev/null || {
    gow_log "[restore] WARNING: could not chown $XDG_RUNTIME_DIR to root"
    return 0
}
gow_log "[restore] ownership restored to $(stat -c '%U:%G' "$XDG_RUNTIME_DIR" 2>/dev/null)"
