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
#########################################
# Kiosk mode: remove ALL sway chrome
#########################################
# Waydroid renders a full Android desktop; gow's sway adds a status bar
# (waybar), window borders and gaps on top of it. Those decorations are wrong
# here -- they steal vertical space, draw a Linux bar across Android's UI, and
# frame the Android window in a Linux border. The user should see Android and
# nothing else.
#
# `launcher()` in /opt/gow/launch-comp.sh does:
#
#     cp /cfg/sway/config $HOME/.config/sway/config
#     echo "output * resolution ..."            >> $HOME/.config/sway/config
#     echo -n "workspace main; exec $@"         >> $HOME/.config/sway/config
#     dbus-run-session -- sway --unsupported-gpu
#
# so it always overwrites $HOME/.config/sway/config from /cfg/sway/config, and
# it appends its own lines afterwards. We cannot stop the copy, but the stock
# config ends with `include /home/retro/.config/sway/custom-cfg`, and the
# appended lines only set the output resolution and the app to exec -- neither
# of which we need to change. So everything we want to override goes into
# custom-cfg, which sway reads last and which therefore wins over:
#
#     gaps inner 4 / gaps outer -4 / gaps top -2      (stock)
#     default_border pixel 2                          (stock)
#     bar { swaybar_command waybar }                  (stock)
#
# WAYDROID_SWAY_CHROME=0 disables this and restores gow's decorations.
if [ -z "$RUN_SWAY" ]; then
    # No nested sway (the default: wolf.config.toml sets RUN_SWAY=false).
    # Waydroid renders straight into Wolf's virtual compositor, so there is no
    # sway bar, border or gap to remove -- everything below is dead work. Skip
    # it rather than log "sway chrome disabled" for a sway never started.
    gow_log "[kiosk] no nested sway; skipping sway/waybar overrides"
elif [ "${WAYDROID_SWAY_CHROME:-0}" = "0" ]; then
    _cfg_dir="$HOME/.config/sway"
    mkdir -p "$_cfg_dir" 2>/dev/null

    # 1) custom-cfg: no gaps, no borders, no titlebars, no bar.
    cat > "${_cfg_dir}/custom-cfg" <<'SWAYEOF'
# Managed by gow-waydroid startup.sh -- kiosk mode, do not edit.
#
# Sway reads this last (the stock config ends with an include of this file),
# so these win over the decoration defaults earlier in the file.
gaps inner 0
gaps outer 0
gaps top 0
gaps bottom 0
gaps left 0
gaps right 0
smart_gaps off
default_border none
default_floating_border none
hide_edge_borders both
# No status bar at all -- this is what removes waybar and its strip of pixels.
bar { mode invisible }
SWAYEOF

    # 2) Neutralise waybar itself. `bar { mode invisible }` above stops sway
    #    from reserving space, but if a waybar process is already spawned it
    #    still draws. launcher() never starts waybar directly -- sway does, via
    #    `bar { swaybar_command waybar }` -- so making the command a no-op is
    #    the reliable belt-and-braces fix.
    #
    #    We cannot edit /cfg/sway/config (launcher re-copies it, and it is in
    #    the read-only image anyway), so we shadow the `waybar` binary with a
    #    stub earlier in PATH. That also kills the "Unable to receive IPC
    #    header" spam when sway's socket is not ready yet.
    _stub_dir="/usr/local/bin"
    if [ -w "$_stub_dir" ] && [ ! -e "${_stub_dir}/waybar" ]; then
        printf '#!/bin/sh\n# Shim: sway chrome disabled by gow-waydroid (kiosk mode).\nexit 0\n' \
            > "${_stub_dir}/waybar" 2>/dev/null && \
            chmod 0755 "${_stub_dir}/waybar" 2>/dev/null && \
            gow_log "[kiosk] waybar shim installed at ${_stub_dir}/waybar"
    fi

    # 3) Write the waybar config too, so that if a real waybar is ever started
    #    it renders an empty, zero-height bar rather than a visible strip.
    mkdir -p "$HOME/.config/waybar" 2>/dev/null
    cat > "$HOME/.config/waybar/config.jsonc" <<'BAREOF'
{
  // Managed by gow-waydroid startup.sh -- intentionally empty.
  "layer": "bottom",
  "height": 0,
  "modules-left": [],
  "modules-center": [],
  "modules-right": []
}
BAREOF
    gow_log "[kiosk] sway chrome disabled (no bar, no borders, no gaps)"
else
    gow_log "[kiosk] WAYDROID_SWAY_CHROME=${WAYDROID_SWAY_CHROME}; keeping gow's sway decorations"
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
        # Pre-grant READ_LOGS (does NOT stop the log-access dialog)
        # ------------------------------------------------------------------
        # CORRECTION: this was originally added believing it would suppress the
        # log-access dialog. It does not, and it cannot. Android 13 deliberately
        # makes READ_LOGS a per-request, one-shot consent:
        #
        #   https://issuetracker.google.com/issues/243904932
        #   "Android 13 shows an allow access dialog when an app that has
        #    READ_LOGS permission runs logcat command"
        #
        # and the permission is declared `prot=signature` here, so `pm grant`
        # reports granted=true while the runtime still refuses, and the app's
        # next attempt re-triggers the dialog. The community consensus is the
        # same: persistent log access is not grantable in A13.
        #
        # The dialog is also a CONSEQUENCE of the crash, not a cause: in the
        # caught session the only LogAccessDialogActivity start (12:43:44.356)
        # came 1.4s AFTER the game's SIGSEGV (12:43:42.937), and the crash
        # process's main thread was inside the tombstone writer reading logs
        # (`__dl_dump_log_file` -> `__dl_LogdRead`). CrashSight collects logs
        # for the crash report, which is what raises the dialog.
        #
        # Kept anyway because it is harmless and does make the permission state
        # honest; it is simply not a fix for the dialog.
        for _pkg in com.tencent.tmgp.sgame com.tencent.tmgp.dfm \
                    com.tencent.tmgp.pubgmhd com.tencent.tmgp.osgame \
                    com.miHoYo.Yuanshen com.netease.x19 \
                    com.valvesoftware.underlords com.taptap; do
            if timeout 30 waydroid shell -- pm list packages 2>/dev/null \
                    | tr -d '\r' | grep -qx "package:${_pkg}"; then
                # Only packages that actually DECLARE READ_LOGS can be granted
                # it; `pm grant` fails for the rest. Checking first keeps the log
                # honest -- without this every app that simply does not request
                # the permission reported "could not grant".
                _pkgdump="$(timeout 30 waydroid shell -- dumpsys package "${_pkg}" 2>/dev/null | tr -d '\r')"
                if ! printf '%s\n' "$_pkgdump" \
                        | grep -q 'android.permission.READ_LOGS'; then
                    continue
                fi
                if printf '%s\n' "$_pkgdump" | grep -q 'READ_LOGS: granted=true'; then
                    gow_log "[logaccess] ${_pkg}: READ_LOGS already granted"
                else
                    timeout 30 waydroid shell -- pm grant "${_pkg}" \
                        android.permission.READ_LOGS >/dev/null 2>&1
                    if timeout 30 waydroid shell -- dumpsys package "${_pkg}" 2>/dev/null \
                            | grep -q 'READ_LOGS: granted=true'; then
                        gow_log "[logaccess] ${_pkg}: READ_LOGS granted"
                    else
                        gow_log "[logaccess] ${_pkg}: WARNING could not grant READ_LOGS"
                    fi
                fi
            fi
        done

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

        # ------------------------------------------------------------------
        # ANR handling -- this is what fixes the BLACK SCREEN.
        # ------------------------------------------------------------------
        # Honor of Kings needs ~9 seconds to process its first
        # FocusEvent(hasFocus=true); Android's per-window input dispatch
        # timeout is a hardcoded 5000ms, so the app is declared ANR during a
        # perfectly healthy start. Measured:
        #
        #     InputDispatcher: a5eff3c ...SGameActivity spent 9183ms
        #         processing FocusEvent(hasFocus=true)
        #
        # The main thread is NOT stuck -- the ANR trace shows it back in
        # __epoll_pwait, having already finished the work.
        #
        # The setting here must be 0 (dialogs ENABLED). With
        # hide_error_dialogs=1 AppErrors auto-answers the ANR with its default
        # choice, which is KILL:
        #
        #     ActivityManager: Killing 5308:com.tencent.tmgp.sgame/u0a126
        #         (adj 102): user request after error
        #
        # so the game dies either way. Keeping the dialog means the app is
        # left running, and waydroid-anrwait (started below) taps "Wait" the
        # moment the dialog appears, clearing the focus blocker without
        # killing anything.
        #
        # Must go through IPlatform: `settings put` via lxc-attach dies with a
        # NullPointerException in AppOpsService.checkPackage because the shell
        # has no calling package.
        _hed="$(timeout 20 waydroid shell -- settings get global hide_error_dialogs \
                2>/dev/null | tr -d '\r' | tail -1)"
        if [ "$_hed" = "0" ]; then
            gow_log "[netfix] hide_error_dialogs already 0"
        else
            if timeout 60 python3 /opt/gow/waydroid-setting.py --int \
                    global hide_error_dialogs 0 2>&1 | sed 's/^/      /'; then
                gow_log "[netfix] hide_error_dialogs=0 (ANR dialog stays, app is not auto-killed)"
            else
                gow_log "[netfix] WARNING: could not set hide_error_dialogs"
            fi
        fi
    ) >>/tmp/waydroid-netfix.log 2>&1 &
    gow_log "[netfix] Background fix started (log: /tmp/waydroid-netfix.log)"
fi

# ---------------------------------------------------------------------------
# OOM guard: protect the game from lmkd.
# ---------------------------------------------------------------------------
# `android.hardware.graphics.allocator@4.0-service.minigbm` leaks one 4KB
# scudo:secondary page per freed graphics buffer and never munmaps it. During
# game battles this passes 20GB in minutes. The allocator runs at
# oom_score_adj=-1000 (unkillable), so lmkd cannot reclaim it and kills the
# GAME instead -- the crash the user sees.
#
# The guard (scripts/waydroid-oomguard.sh) demotes the allocator so lmkd may
# reclaim it, pins the games at a protected adj, and restarts the allocator if
# it crosses a hard ceiling. It scans /proc because `waydroid shell -- pidof`
# is unusably slow and does not report the host-visible PID.
#
# IMPORTANT: run these helpers DIRECTLY, never through `launcher`.
# ------------------------------------------------------------------
# gow's launcher() does not merely exec a command -- with RUN_SWAY set it
# STARTS A SWAY COMPOSITOR for whatever it is given:
#
#     elif [ -n "$RUN_SWAY" ]; then
#         echo -n "workspace main; exec $@" >> $HOME/.config/sway/config
#         dbus-run-session -- sway --unsupported-gpu
#
# so calling it once per helper spawned one sway per helper. Measured with
# RUN_SWAY=1 and both helpers enabled:
#
#     1283 sway --unsupported-gpu
#     1284 sway --unsupported-gpu
#     1287 sway --unsupported-gpu
#
# Three compositors then fought over the same output and the renderer stalled:
#
#     [ERROR] [wlr] [render/swapchain.c:98] No free output buffer slot
#
# and the Waydroid session ended up STOPPED with no UI, because only the last
# sway carried the `exec ... show-full-ui` line. Background helpers are plain
# daemons and need no compositor at all.
if [ "${WAYDROID_OOM_GUARD:-1}" != "0" ]; then
    if [ -x /usr/local/bin/waydroid-oomguard ]; then
        /usr/local/bin/waydroid-oomguard &
        gow_log "[oomguard] Background guard started (log: /tmp/waydroid-oomguard.log)"
    else
        gow_log "[oomguard] WARNING: /usr/local/bin/waydroid-oomguard missing"
    fi
fi

# Tap "Wait" on startup ANR dialogs so the game is not auto-killed.
#
# Games launched through the ARM translator need ~9s to answer the first
# focus event, past Android's hardcoded 5s input timeout, so an ANR is
# unavoidable -- but the app is healthy. With the dialog enabled the app keeps
# running; this helper dismisses the dialog for us. See
# scripts/waydroid-anrwait.sh for the full explanation.
if [ "${WAYDROID_ANR_AUTOWAIT:-1}" != "0" ]; then
    if [ -x /usr/local/bin/waydroid-anrwait ]; then
        /usr/local/bin/waydroid-anrwait &
        gow_log "[anrwait] ANR auto-wait started (log: /tmp/waydroid-anrwait.log)"
    else
        gow_log "[anrwait] WARNING: /usr/local/bin/waydroid-anrwait missing"
    fi
fi

# Reinstall apps that PackageManager dropped. Android reconciles /data/app
# against /data/system/packages.xml at boot and removes any directory with no
# matching record -- which wipes every installed game whenever packages.xml has
# to be reset (e.g. switching Android versions). APKs are stashed outside
# userdata and reinstalled once boot completes. See the script header.
if [ "${WAYDROID_APP_RESTORE:-1}" != "0" ]; then
    if [ -x /usr/local/bin/waydroid-apprestore ]; then
        /usr/local/bin/waydroid-apprestore &
        gow_log "[apprestore] Background app-restore started (log: /tmp/waydroid-apprestore.log)"
    else
        gow_log "[apprestore] WARNING: /usr/local/bin/waydroid-apprestore missing"
    fi
fi

if [ "$WAYDROID_UI_MODE" = "full" ]; then
    gow_log "[waydroid] Starting full Android UI"
    # ------------------------------------------------------------------
    # Keep the Waydroid SESSION on OUR session bus, not sway's.
    # ------------------------------------------------------------------
    # gow's launcher starts sway as:
    #
    #     dbus-run-session -- sway --unsupported-gpu
    #
    # and `dbus-run-session` ALWAYS spawns a brand new session bus, exporting
    # its own DBUS_SESSION_BUS_ADDRESS into the child. Measured directly:
    #
    #     $ export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/testbus
    #     $ dbus-run-session -- sh -c 'echo $DBUS_SESSION_BUS_ADDRESS'
    #     unix:path=/tmp/dbus-qxcnyVNcqI,guid=...      <- a NEW bus, ours is gone
    #
    # (DBUS_RUN_SESSION_BUS_ADDRESS does NOT make it reuse an existing bus --
    # that was tested and does not work.)
    #
    # So the sway `exec` line runs show-full-ui on a bus where no Waydroid
    # session service exists. app_manager.maybeLaunchLater() then falls back to
    # session_manager.start(), and because the container manager already holds a
    # session it raises "Already tracking a session" -- observed x3, killing the
    # container 3 seconds after launch with exit code 143:
    #
    #     [Sway] - Starting: `/usr/bin/waydroid show-full-ui`
    #     [04:36:19] Starting waydroid session
    #     [04:36:19] RuntimeError: Already tracking a session
    #     Gdk-Message: Error reading events from display: Broken pipe
    #
    # Fix, part 1 of 2 -- DO NOT pass the address as an `env` prefix on the
    # launcher command line.
    #
    # gow's `launcher()` does not exec its arguments; it splices them into a
    # sway config file as a text line:
    #
    #     echo -n "workspace main; exec $@" >> $HOME/.config/sway/config
    #
    # sway treats ',' as a COMMAND SEPARATOR, and dbus-daemon always prints the
    # address with a ",guid=..." suffix. So the prefix is torn in half and sway
    # rejects the whole line, meaning show-full-ui never runs at all:
    #
    #     [Sway] - Starting: `env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/
    #         wolf/dbus-session-0,guid=ec8a543f0ef44dff1ea6f6db6aaaa28d
    #         /usr/bin/waydroid show-full-ui`
    #     [ERROR] [sway/config.c:694] Error on line 'workspace main; exec env
    #         DBUS_SESSION_BUS_ADDRESS=unix:path=...,guid=ec8a54... /usr/bin/
    #         waydroid show-full-ui && killall sway': Unknown/invalid command
    #         'guid=ec8a543f0ef44dff1ea6f6db6aaaa28d'
    #
    # Nothing in the exec line may therefore contain a comma. Our bus socket
    # lives at a fixed, comma-free path (${XDG_RUNTIME_DIR}/dbus-session-$(id
    # -u)), so we export the COMMA-FREE socket path under a private variable
    # and let the shell sway spawns compose the real address. Verified in a
    # live sway (see waydroid-work/sway-env-probe2.sh): the exec child
    # inherits arbitrary exported vars, and DBUS_SESSION_BUS_ADDRESS that the
    # child exports itself survives, reaching our bus.
    #
    # Fix, part 2 of 2 -- launch a tiny wrapper rather than the bare binary, so
    # the exec line is a single comma-free word.
    _waydroid_bus="${DBUS_SESSION_BUS_ADDRESS:-}"
    _waydroid_sock="${XDG_RUNTIME_DIR}/dbus-session-$(id -u)"
    if [ -n "$_waydroid_bus" ]; then
        gow_log "[waydroid] Pinning show-full-ui to session D-Bus ${_waydroid_bus}"
        gow_log "[waydroid]    (comma-free socket passed via WAYDROID_BUS_EXPORT=${_waydroid_sock})"
        export WAYDROID_BUS_EXPORT="unix:path=${_waydroid_sock}"
        launcher /usr/local/bin/waydroid-ui
    else
        gow_log "[waydroid] WARNING: no session D-Bus address; show-full-ui will autolaunch"
        launcher /usr/local/bin/waydroid-ui
    fi
else
    if [ -z "$WAYDROID_APP_PACKAGE" ]; then
        gow_log "[waydroid] WAYDROID_UI_MODE=single but WAYDROID_APP_PACKAGE is unset"
        exit 1
    fi
    gow_log "[waydroid] Starting single app: ${WAYDROID_APP_PACKAGE}"
    if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        export WAYDROID_BUS_EXPORT="unix:path=${XDG_RUNTIME_DIR}/dbus-session-$(id -u)"
        launcher /usr/local/bin/waydroid-app "${WAYDROID_APP_PACKAGE}"
    else
        launcher /usr/local/bin/waydroid-app "${WAYDROID_APP_PACKAGE}"
    fi
fi
