#!/bin/bash
set -e

source /opt/gow/bash-lib/utils.sh
source /opt/gow/launch-comp.sh

gow_log "Waydroid startup.sh"

# NOTE ON PRIVILEGES
# ------------------
# This script runs as ${UNAME} (uid 1000), NOT as root -- see gow's base
# entrypoint, which does `exec gosu "${UNAME}" /opt/gow/startup.sh`.
#
# All privileged setup (mounting binderfs, starting the system D-Bus daemon,
# creating the waydroid0 bridge, installing NAT rules) therefore lives in
# /etc/cont-init.d/20-waydroid-setup.sh, which the entrypoint sources as root
# beforehand. Anything added here must work unprivileged.
#
# The failure that taught us this:
#     [dbus] Starting system bus
#     mkdir: cannot create directory '/run/dbus': Permission denied

#########################################
# Sanity check: did the privileged stage run?
#########################################
# Because cont-init.d and this script run in different privilege contexts, a
# partial failure upstream shows up here as a confusing downstream error.
# Check the two hard requirements up front and say something actionable.
if [ ! -S /run/dbus/system_bus_socket ]; then
    gow_log "[waydroid] WARNING: system D-Bus socket missing."
    gow_log "[waydroid]    The CLI will fail with a D-Bus connection error."
    gow_log "[waydroid]    Check that /etc/cont-init.d/20-waydroid-setup.sh ran."
fi

if [ ! -e /dev/binderfs/binder-control ] && [ ! -e /dev/binder ]; then
    gow_log "[waydroid] WARNING: no binder device available."
    gow_log "[waydroid]    Android cannot start without binderfs."
    gow_log "[waydroid]    Needs CAP_SYS_ADMIN, or --device=/dev/binder."
fi

#########################################
# Display environment
#########################################
# This MUST be decided here rather than in cont-init.d: this script runs as a
# separate process via `gosu ${UNAME}`, so it does not inherit anything
# exported by the init scripts.
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/.X11-unix}"
export XDG_RUNTIME_DIR

if [ ! -d "$XDG_RUNTIME_DIR" ] || [ ! -w "$XDG_RUNTIME_DIR" ]; then
    gow_log "[waydroid] WARNING: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR missing or unwritable"
    gow_log "[waydroid]    sway cannot publish its IPC socket; waybar will flood"
    gow_log "[waydroid]    the log with 'Unable to receive IPC header'."
fi

# ---------------------------------------------------------------------------
# Compositor selection and display wiring.
#
# gow's shared launch-comp.sh (from base-app) picks the compositor via:
#
#     if   [ -n "$RUN_GAMESCOPE" ]; then ...gamescope...
#     elif [ -n "$RUN_SWAY" ]; then ...sway...
#     else ...plain exec...
#
# Two facts we have to work around here:
#
#   1. `-n` means NON-EMPTY, so `RUN_SWAY=0` does NOT disable sway -- the
#      literal string "0" is non-empty, so the sway branch is still taken.
#      People naturally use "0"/"false" as off-switches, and it silently
#      does the opposite. We therefore normalise falsy values to unset before
#      `launcher` runs.
#
#   2. When BOTH compositors are off (RUN_SWAY=0 and no RUN_GAMESCOPE),
#      waydroid renders DIRECTLY into whatever $WAYLAND_DISPLAY points at --
#      under Wolf that is the virtual compositor's socket, and this is the
#      intended "no nested sway" mode. In that case WLR_BACKENDS is irrelevant
#      (sway is not started) but we still need $WAYLAND_DISPLAY to be usable,
#      so we resolve it to an absolute path.
_is_falsy() {
    case "${1:-}" in
        ""|0|false|False|FALSE|no|No|NO|off|Off|OFF|disable|Disable|DISABLE|disabled|Disabled|DISABLED)
            return 0 ;;
        *) return 1 ;;
    esac
}

if _is_falsy "$RUN_SWAY"; then
    gow_log "[waydroid] RUN_SWAY is falsy ($RUN_SWAY); disabling sway"
    unset RUN_SWAY
fi
if _is_falsy "$RUN_GAMESCOPE"; then
    gow_log "[waydroid] RUN_GAMESCOPE is falsy ($RUN_GAMESCOPE); disabling gamescope"
    unset RUN_GAMESCOPE
fi

if [ -n "$RUN_GAMESCOPE" ]; then
    gow_log "[waydroid] Compositor: gamescope"
    export WLR_BACKENDS="${WLR_BACKENDS:-wayland}"
elif [ -n "$RUN_SWAY" ]; then
    gow_log "[waydroid] Compositor: sway"
    # sway cannot be the PRIMARY compositor in a container: wlroots needs a
    # DRM device AND a seat/VT, and there is no logind seat here -- it stops
    # at "Waiting for a session to become active" and never publishes its IPC
    # socket, which makes waybar spam "Unable to receive IPC header". So sway
    # must NEST on Wolf's virtual compositor.
    export WLR_BACKENDS="${WLR_BACKENDS:-wayland}"
    export WLR_LIBINPUT_NO_DEVICES="${WLR_LIBINPUT_NO_DEVICES:-1}"
else
    gow_log "[waydroid] Compositor: none (RUN_SWAY/RUN_GAMESCOPE off)"
    gow_log "[waydroid]    Waydroid renders directly into \$WAYLAND_DISPLAY."
fi

# Resolve $WAYLAND_DISPLAY to an absolute path where possible, because Wolf
# mounts its socket at a path that may not match $XDG_RUNTIME_DIR exactly.
# Both libwayland and waydroid accept an absolute WAYLAND_DISPLAY.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
        /*)
            # already absolute: trust it if present
            if [ -S "$WAYLAND_DISPLAY" ]; then
                gow_log "[waydroid] Wayland socket: $WAYLAND_DISPLAY"
            else
                gow_log "[waydroid] WARNING: Wayland socket not found at $WAYLAND_DISPLAY"
            fi
            ;;
        *)
            _resolved=""
            for cand in                 "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"                 "/run/user/$(id -u)/${WAYLAND_DISPLAY}"                 "/tmp/${WAYLAND_DISPLAY}"                 "${XDG_RUNTIME_DIR}/wayland-0"                 "/run/user/$(id -u)/wayland-0"
            do
                if [ -S "$cand" ]; then _resolved="$cand"; break; fi
            done
            if [ -n "$_resolved" ]; then
                gow_log "[waydroid] Resolved Wayland socket: $WAYLAND_DISPLAY -> $_resolved"
                export WAYLAND_DISPLAY="$_resolved"
            else
                gow_log "[waydroid] WARNING: could not find Wayland socket for '$WAYLAND_DISPLAY'"
                gow_log "[waydroid]    looked in: $XDG_RUNTIME_DIR/ /run/user/$(id -u)/ /tmp/"
            fi
            ;;
    esac
else
    gow_log "[waydroid] WAYLAND_DISPLAY unset"
    if [ -n "$RUN_SWAY" ] || [ -n "$RUN_GAMESCOPE" ]; then
        gow_log "[waydroid]    Will run headless (no parent compositor provided)."
    else
        gow_log "[waydroid]    Waydroid needs a Wayland compositor to render into."
        gow_log "[waydroid]    Ensure Wolf sets start_virtual_compositor = true."
    fi
fi

gow_log "[waydroid] WLR_BACKENDS=${WLR_BACKENDS:-<unset>} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
# Optional: silence waybar's sway modules
#########################################
# The five sway/* waybar modules each poll sway's IPC socket and, if sway is
# not answering, retry in a tight loop. One bad start produces hundreds of:
#
#     [error] Workspaces: Unable to receive IPC header
#
# which buries the actual failure. Setting WAYDROID_QUIET_BAR=1 writes a
# reduced waybar config first; launch-comp.sh copies /cfg/waybar/* with
# `cp -u` (only if newer), so a file we place here wins.
#
# This is deliberately OPT-IN: the default keeps gow's full status bar,
# because changing what the user sees by default would be surprising.
if [ "${WAYDROID_QUIET_BAR:-0}" = "1" ]; then
    if [ -f /cfg/waybar/config.jsonc ]; then
        mkdir -p "$HOME/.config/waybar"
        # Strip the sway/* modules from modules-left/center/right, leaving
        # the rest of the bar intact.
        python3 - <<'PYEOF' 2>/dev/null || gow_log "[waydroid] quiet-bar: could not rewrite config"
import json, re, sys
src = "/cfg/waybar/config.jsonc"
dst = __import__("os").path.expanduser("~/.config/waybar/config.jsonc")
raw = open(src).read()
# The file is JSONC (comments allowed); strip // comments before parsing.
raw = re.sub(r'^\s*//.*$', '', raw, flags=re.M)
cfg = json.loads(raw)
drop = lambda names: [m for m in names if not m.startswith("sway/")]
for key in ("modules-left", "modules-center", "modules-right"):
    if key in cfg:
        cfg[key] = drop(cfg[key])
open(dst, "w").write(json.dumps(cfg, indent=2))
PYEOF
        gow_log "[waydroid] quiet-bar: sway/* modules removed from waybar"
    fi
else
    gow_log "[waydroid] Full waybar config (set WAYDROID_QUIET_BAR=1 to trim sway modules)"
fi

#########################################
# Per-user state
#########################################
if [ ! -d "$HOME/.local/share/waydroid" ]; then
    gow_log "[waydroid] Creating session state dir"
    mkdir -p "$HOME/.local/share/waydroid"
fi

#########################################
# Android system image
#########################################
# The image download/init happens in /etc/cont-init.d/20-waydroid-setup.sh,
# NOT here, because `waydroid init` refuses to run as non-root
# (tools/__init__.py: `if os.geteuid() != 0: raise RuntimeError(...)`).
#
# cont-init deliberately does NOT download on every start -- that would block
# plain `docker run` for the length of an 838MB transfer and break the CI
# smoke layers. So if the images are missing we leave a marker that the root
# stage picks up on the next start, and say so plainly.
WAYDROID_WORK="${WAYDROID_WORK:-/var/lib/waydroid}"

# What "initialized" MEANS, taken from waydroid 1.6.2 source rather than
# guessed. tools/actions/initializer.py:
#
#     def is_initialized(args):
#         return os.path.isfile(args.config) and os.path.isdir(
#             tools.config.defaults["rootfs"])
#
# with args.config = /var/lib/waydroid/waydroid.cfg and rootfs =
# /var/lib/waydroid/rootfs. A system.img on its own is NOT sufficient.
#
# An earlier revision of this script only checked images/system.img, so on a
# machine whose download had been interrupted it wrongly reported
# "Using existing system image" and then black-screened, because waydroid
# itself still considered the install uninitialised.
if [ ! -f "${WAYDROID_WORK}/waydroid.cfg" ] || [ ! -d "${WAYDROID_WORK}/rootfs" ]; then
    gow_log "[waydroid] Android images missing."
    if mkdir -p "$WAYDROID_WORK" 2>/dev/null && \
       touch "${WAYDROID_WORK}/.init-requested" 2>/dev/null; then
        gow_log "[waydroid]    Download requested for the next start; the ~1.5GB"
        gow_log "[waydroid]    fetch then runs as root. Restart to trigger it."
    else
        gow_log "[waydroid]    Could not write the init marker; run manually:"
        gow_log "[waydroid]      docker exec <container> waydroid-setup.sh init"
    fi
    gow_log "[waydroid]    Or bake at build time with:"
    gow_log "[waydroid]      --build-arg BAKE_ANDROID_IMAGE=true"
else
    gow_log "[waydroid] Waydroid is initialised (waydroid.cfg + rootfs present)"
fi

#########################################
# Container manager
#########################################
# Waydroid upstream is driven by a systemd unit + D-Bus activation. Neither
# exists in these containers (the base image has no systemd), so we start the
# same entry point the unit calls and wait for it to become reachable.
#
# THE MANAGER IS STARTED BY /etc/cont-init.d/20-waydroid-setup.sh, NOT HERE.
# `waydroid container start` requires root:
#     ERROR: Action "container" needs root access
# This script runs as uid 1000, so calling it here silently failed and the
# session then launched against a dead manager -- which is exactly the black
# screen this code used to cause. The manager is backgrounded from the root
# init stage; it lives for the life of the container, and the D-Bus name it
# owns is on the shared system bus, so we can observe it from here.
#
# HOW TO CHECK READINESS -- and a bug this replaces:
# there is NO `waydroid container status` subcommand. `waydroid container`
# only accepts start|stop|restart|freeze|unfreeze, so the earlier check here
# always failed with "invalid choice: 'status'" and printed a misleading
# "did not report ready" on every start.
#
# The correct signal is the D-Bus name the manager owns: the upstream unit
# declares `BusName=id.waydro.Container` and dbus/id.waydro.Container.conf
# grants root ownership of exactly that name.
waydroid_manager_up() {
    dbus-send --system --dest=org.freedesktop.DBus --type=method_call \
        --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames \
        2>/dev/null | grep -q '"id.waydro.Container"'
}

for _ in $(seq 1 15); do
    waydroid_manager_up && break
    sleep 1
done

if waydroid_manager_up; then
    gow_log "[waydroid] Container manager is up"
else
    gow_log "[waydroid] WARNING: container manager did not register id.waydro.Container"
    gow_log "[waydroid]    Log from 'waydroid container start' (run during init):"
    sed 's/^/      /' /tmp/waydroid-container.log 2>/dev/null | tail -15
fi

# Session
#########################################
# Waydroid's SESSION runs on a D-Bus *session* bus: `waydroid show-full-ui`
# -> maybeLaunchLater -> DBusSessionService() -> dbus.SessionBus().get_object(
# "id.waydro.Session", ...), and session_manager.start() takes its BusName on
# dbus.SessionBus() too. Only the CONTAINER manager uses the system bus.
#
# With RUN_SWAY=0 there is no sway and therefore no $DISPLAY, so dbus-python's
# session-bus autolaunch fails with:
#
#     ERROR: org.freedesktop.DBus.Error.NotSupported:
#         Unable to autolaunch a dbus-daemon without a $DISPLAY for X11
#
# That autolaunch is an X11-ism and is irrelevant to waydroid, which only
# needs a reachable session bus. We therefore start one here ourselves and
# export its address; dbus.SessionBus() then connects to it directly instead
# of trying (and failing) to autolaunch.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || \
   ! dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
        --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames \
        >/dev/null 2>&1; then
    # A per-container socket inside the (writable) runtime dir, keyed by uid so
    # a re-run or a second user cannot collide with a stale socket.
    _sb_sock="${XDG_RUNTIME_DIR}/dbus-session-$(id -u)"
    mkdir -p "$(dirname "$_sb_sock")" 2>/dev/null
    if _sb_addr="$(dbus-daemon --session --fork --print-address=1 \
        --address="unix:path=${_sb_sock}" 2>/dev/null)"; then
        export DBUS_SESSION_BUS_ADDRESS="${_sb_addr}"
        gow_log "[waydroid] Started session D-Bus at ${_sb_sock}"
    else
        gow_log "[waydroid] WARNING: could not start a session D-Bus daemon;"
        gow_log "[waydroid]    show-full-ui may fail with a NotSupported autolaunch error"
    fi
else
    gow_log "[waydroid] Using existing session D-Bus: ${DBUS_SESSION_BUS_ADDRESS}"
fi

# `show-full-ui` renders the whole Android desktop, which is what we want for
# a streamed session. The alternative renders a single app.
WAYDROID_UI_MODE="${WAYDROID_UI_MODE:-full}"

#########################################
# Captive-portal / network validation fix
#########################################
# Android's connectivity validator probes www.google.com over HTTPS. From
# mainland China that host resolves but its TCP 443/80 connections time out,
# so validation never succeeds and the network stays in PARTIAL_CONNECTIVITY:
#
#     PROBE_HTTPS https://www.google.com/generate_204 -> SocketTimeoutException
#     isCaptivePortal: isSuccessful()=false isPortal()=false
#                      isPartialConnectivity()=true
#     ConnectivityService: [100 ETHERNET] validation failed
#
# Android gates content downloads on a fully VALIDATED network, so the visible
# symptom is that downloads sit in the queue forever -- on BOTH the Android 13
# TV and non-TV images -- even though ping, DNS and the fallback probe all work.
#
# Setting captive_portal_mode=0 makes NetworkMonitor skip probing entirely
# ("Validation disabled.") and ConnectivityService marks the network validated.
#
# This has to run AFTER Android boots, but `launcher` below blocks for the
# whole session, so the fix runs as a background child. It is written to be
# cheap and idempotent: a marker file short-circuits it once applied, and it
# exits quietly if Android never comes up.
if [ "${WAYDROID_SKIP_NETWORK_FIX:-0}" != "1" ]; then
    gow_log "[waydroid] Scheduling captive-portal fix (background)"
    (
        # Give Android time to boot. If it is already up the first check
        # succeeds immediately.
        _booted=""
        for _ in $(seq 1 60); do
            if [ "$(timeout 20 waydroid shell -- getprop sys.boot_completed 2>/dev/null \
                    | tr -d '\r' | tail -1)" = "1" ]; then
                _booted=1
                break
            fi
            sleep 5
        done

        if [ -z "$_booted" ]; then
            gow_log "[netfix] Android never reported boot_completed; giving up"
            exit 0
        fi

        _need_restart=0

        # captive_portal_mode must be written through IPlatform (waydroid-setting.py),
        # NOT by rewriting the ABX store. The ABX rewrite is reverted by
        # SettingsProvider on the next shutdown (the exact bug the policy_control
        # block below works around with IPlatform), and the settings(1) CLI NPEs
        # through waydroid shell. A full `waydroid container restart` is required
        # afterwards: NetworkMonitor reads captive_portal_mode only at creation,
        # so a soft `waydroid shell -- stop` reuses the old NetworkMonitor and the
        # value stays ignored (verified: network stayed PARTIAL_CONNECTIVITY until
        # a real container restart recreated NetworkMonitor).
        if [ "$(timeout 20 waydroid shell -- settings get global captive_portal_mode \
                2>/dev/null | tr -d '\r' | tail -1)" = "0" ]; then
            gow_log "[netfix] captive_portal_mode already 0"
        else
            gow_log "[netfix] Applying captive_portal_mode=0 via IPlatform"
            if timeout 60 python3 /opt/gow/waydroid-setting.py --int \
                    global captive_portal_mode 0 2>&1 | sed 's/^/      /'; then
                # China-reachable probe URLs, so validation succeeds even on hosts
                # where www.google.com / play.googleapis.com are unreachable.
                timeout 60 python3 /opt/gow/waydroid-setting.py \
                    global captive_portal_http_url "http://connectivitycheck.gstatic.com/generate_204" 2>&1 | sed 's/^/      /'
                timeout 60 python3 /opt/gow/waydroid-setting.py \
                    global captive_portal_https_url "https://connectivitycheck.gstatic.com/generate_204" 2>&1 | sed 's/^/      /'
                timeout 60 python3 /opt/gow/waydroid-setting.py --int \
                    global captive_portal_use_https 1 2>&1 | sed 's/^/      /'
                gow_log "[netfix] captive-portal settings written via IPlatform"
                _need_restart=1
            else
                gow_log "[netfix] WARNING: could not write captive_portal_mode"
            fi
        fi

        # NetworkMonitor only reads captive_portal_mode when it is (re)created,
        # so a full container restart is required. `waydroid shell -- stop` is
        # NOT enough (verified: validation stayed PARTIAL_CONNECTIVITY).
        if [ "$_need_restart" = "1" ]; then
            gow_log "[netfix] Restarting the waydroid container to recreate NetworkMonitor"
            timeout 120 waydroid container restart >/dev/null 2>&1 || true
            sleep 15
            for _ in $(seq 1 60); do
                if [ "$(timeout 20 waydroid shell -- getprop sys.boot_completed 2>/dev/null \
                        | tr -d '\r' | tail -1)" = "1" ]; then
                    break
                fi
                sleep 5
            done
        fi

        _mode="$(timeout 20 waydroid shell -- settings get global captive_portal_mode \
                 2>/dev/null | tr -d '\r' | tail -1)"
        if [ "$_mode" = "0" ]; then
            gow_log "[netfix] captive_portal_mode=0 confirmed; downloads can dequeue"
        else
            gow_log "[netfix] WARNING: captive_portal_mode reads '${_mode}'"
        fi

        # ------------------------------------------------------------------
        # Hide the taskbar so touches reach the game.
        # ------------------------------------------------------------------
        # The default is `immersive.status=*`, which hides only the status bar.
        # Android TV's TaskbarManager then stays on top and swallows taps aimed
        # at a fullscreen game, so the game appears frozen on a dialog that can
        # never be dismissed. `immersive.full=*` hides both bars.
        #
        # This must go through IPlatform (waydroid-setting.py): the settings(1)
        # CLI NPEs via waydroid shell, and editing the ABX store directly is
        # reverted by SettingsProvider on the next shutdown.
        _pc="$(timeout 20 waydroid shell -- settings get global policy_control \
               2>/dev/null | tr -d '\r' | tail -1)"
        if [ "$_pc" = "immersive.full=*" ]; then
            gow_log "[netfix] policy_control already immersive.full=*"
        else
            gow_log "[netfix] Setting policy_control=immersive.full=* (was '${_pc}')"
            if timeout 60 python3 /opt/gow/waydroid-setting.py \
                    global policy_control "immersive.full=*" 2>&1 | sed 's/^/      /'; then
                gow_log "[netfix] Taskbar hidden; touches reach the game"
            else
                gow_log "[netfix] WARNING: could not set policy_control"
            fi
        fi
    ) >>/tmp/waydroid-netfix.log 2>&1 &
    gow_log "[netfix] Background fix started (log: /tmp/waydroid-netfix.log)"
fi

if [ "$WAYDROID_UI_MODE" = "full" ]; then
    gow_log "[waydroid] Starting full Android UI"
    launcher /usr/bin/waydroid show-full-ui
else
    if [ -z "$WAYDROID_APP_PACKAGE" ]; then
        gow_log "[waydroid] WAYDROID_UI_MODE=single but WAYDROID_APP_PACKAGE is unset"
        exit 1
    fi
    gow_log "[waydroid] Starting single app: ${WAYDROID_APP_PACKAGE}"
    launcher /usr/bin/waydroid app launch "${WAYDROID_APP_PACKAGE}"
fi
