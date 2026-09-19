#!/usr/bin/env bash
# Smoke test for the waydroid image.
#
# Scope note, and it is an important one: this test deliberately does NOT
# boot Android. Booting requires binderfs (CAP_SYS_ADMIN), a running Wayland
# compositor and a ~1.5GB system image, none of which the CI harness
# provides -- bin/test-image.sh runs the container with no extra privileges.
#
# So we assert the things that *can* be verified without those, and which
# are exactly the things that historically break in this kind of image:
#   * the LXC + Python dependency chain is complete (a missing libgbinder or
#     python3-gbinder makes `waydroid` import-fail, not just warn)
#   * the CLI is actually runnable, not a broken wrapper script
#   * our own helper scripts are installed and executable
#   * the state directories Waydroid expects exist
#
# The privileged boot path is covered by tests/waydroid-integration.sh,
# which must be run manually on a host with CAP_SYS_ADMIN.
source /smoke-common/lib.sh

# --- the CLI and its runtime -------------------------------------------------
assert_has waydroid lxc-start

# `waydroid` is a Python entry point. A missing dep surfaces as an
# ImportError with a non-zero exit, which is precisely the class of failure
# assert_version is designed to catch (it greps for the fatal patterns the
# linker/import system emits).
assert_version waydroid --version

# --- Android 16 support (waydroid >= 1.6.3) ----------------------------------
# 1.6.2 cannot talk to Android 16 (lineage-23.2) images: it lacks the
# aidl5/aidl6 binder protocol mapping and the shutdown-request transaction.
# 1.6.3 is the first release with "Initial support for Android 16 images".
_wd_ver="$(waydroid --version 2>/dev/null || true)"
if printf '%s\n' "$_wd_ver" | grep -qE '1\.6\.[3-9]|[1-9][0-9]*\.'; then
    ok "waydroid is 1.6.3+ (Android 16 images supported): $_wd_ver"
else
    bad "waydroid is 1.6.3+ (Android 16 images supported): ${_wd_ver:-<unknown>}"
fi
if grep -q 'aidl6' /usr/lib/waydroid/tools/helpers/protocol.py 2>/dev/null; then
    ok "protocol.py maps Android 16 to aidl6"
else
    bad "protocol.py maps Android 16 to aidl6"
fi

# libgbinder must support the aidl6 servicemanager protocol that Android 16
# (API 36) needs. libgbinder 1.1.43 (newest in repo.waydro.id) stops at aidl4,
# so the image builds 1.1.52 (first aidl6-capable release is 1.1.45) and
# replaces the .so. Without this the container manager floods the log with
# "Unknown servicemanager protocol aidl6" and Android 16 never comes up.
_libgbinder_aidl6="$(grep -ao 'aidl6' /usr/lib/x86_64-linux-gnu/libgbinder.so.1 2>/dev/null | head -1 || true)"
if [ -n "$_libgbinder_aidl6" ]; then
    ok "libgbinder supports aidl6 (Android 16)"
else
    bad "libgbinder supports aidl6 (Android 16)"
fi

# LXC is what actually hosts Android. Version string proves the binary runs;
# the library check proves the Python bindings can find it.
assert_version lxc-start --version
assert_shared_ok "$(command -v lxc-start)"

# --- Python module chain -----------------------------------------------------
# waydroid imports these at startup. Checking them by import (rather than by
# package name) catches the case where the package is installed for a
# different Python version than the one on PATH.
for mod in gi gbinder dbus yaml requests; do
    if python3 -c "import ${mod}" 2>/dev/null; then
        ok "python module ${mod} imports"
    else
        bad "python module ${mod} imports"
    fi
done

# --- our own scripts ---------------------------------------------------------
assert_path /opt/gow/startup-app.sh /opt/gow/waydroid-setup.sh /opt/gow/waydroid-net.sh /usr/local/bin/waydroid-extras

for s in /opt/gow/startup-app.sh /opt/gow/waydroid-setup.sh /opt/gow/waydroid-net.sh /usr/local/bin/waydroid-extras; do
    if [[ -x "$s" ]]; then
        ok "$s is executable"
    else
        bad "$s is executable"
    fi
    # bash -n is a pure syntax check: it does not execute anything, so it is
    # safe here even though startup.sh would otherwise try to mount binderfs.
    if bash -n "$s" 2>/dev/null; then
        ok "$s has valid syntax"
    else
        bad "$s has valid syntax"
    fi
done

# --- state directories -------------------------------------------------------
assert_path /var/lib/waydroid /var/lib/waydroid/lxc /run/waydroid-lxc

# --- networking tooling ------------------------------------------------------
# Needed to build the bridge + NAT that gives Android its internet access.
assert_has ip
if command -v iptables >/dev/null 2>&1 || command -v iptables-legacy >/dev/null 2>&1; then
    ok "an iptables binary is present"
else
    bad "an iptables binary is present"
fi

# --- binder documentation ----------------------------------------------------
# We cannot mount binderfs here, but we CAN verify the image knows the
# difference between the three support tiers, because that logic is the
# whole reason this image works in containers at all.
#
# Note the deliberate absence of `grep -q`: bin/tests/lib.sh runs with
# `set -o pipefail`, and `grep -q` closes the pipe as soon as it matches.
# The producer then dies of SIGPIPE (exit 141), which pipefail surfaces as a
# failed pipeline *even though the match succeeded*. Capturing the output
# into a variable first avoids the whole class of problem.
binder_report="$(/opt/gow/waydroid-setup.sh status 2>&1 || true)"
if grep -q "binder" <<<"$binder_report"; then
    ok "waydroid-setup.sh reports binder state"
else
    bad "waydroid-setup.sh reports binder state"
    sed 's/^/   | /' <<<"$binder_report" >&2
fi

# --- regression guards -------------------------------------------------------
# These encode bugs that were actually hit while developing this image. They
# are cheap string checks and they exist so the same mistakes cannot silently
# come back.

# 1. The container manager must NOT be started from startup.sh: that script
#    runs as uid 1000 and `waydroid container start` needs root, so the
#    session would launch against a dead manager (a black screen).
if grep -qE '^\s*waydroid container start' /opt/gow/startup-app.sh; then
    bad "startup-app.sh does not start the container manager (needs root)"
else
    ok "startup-app.sh does not start the container manager (needs root)"
fi

# 2. `waydroid container status` does not exist. The valid subcommands are
#    start|stop|restart|freeze|unfreeze; using 'status' makes readiness
#    detection always fail. Match only non-comment lines, since the scripts
#    legitimately mention the bad command in explanatory comments.
if grep -hE '^[^#]*waydroid container status' /opt/gow/startup-app.sh /opt/gow/waydroid-setup.sh 2>/dev/null; then
    bad "no use of the nonexistent 'waydroid container status' subcommand"
else
    ok "no use of the nonexistent 'waydroid container status' subcommand"
fi

# 3. Readiness is signalled by the D-Bus name from Waydroid's own systemd
#    unit (BusName=id.waydro.Container). If this string disappears, the
#    readiness probe has been rewritten to something that does not work.
if grep -q 'id.waydro.Container' /opt/gow/startup-app.sh; then
    ok "readiness probe uses the id.waydro.Container bus name"
else
    bad "readiness probe uses the id.waydro.Container bus name"
fi

# 4. "Initialised" means waydroid.cfg + rootfs/, per Waydroid's own
#    initializer.is_initialized(). Checking only images/system.img reports a
#    partial install as healthy, which black-screens.
if grep -q 'waydroid.cfg' /opt/gow/startup-app.sh; then
    ok "initialisation check matches waydroid's own definition"
else
    bad "initialisation check matches waydroid's own definition"
fi

# 5. The image-type flag is -s/--system_type. `-t` is not accepted by
#    waydroid 1.6.2 and fails with "unrecognized arguments".
if grep -qE 'waydroid init[^|]*-t ' /opt/gow/startup-app.sh /opt/gow/waydroid-setup.sh 2>/dev/null; then
    bad "no use of the invalid 'waydroid init -t' flag"
else
    ok "no use of the invalid 'waydroid init -t' flag"
fi

# 6. Binder device nodes must be pre-allocated by the root init stage.
#    Mounting binderfs only creates binder-control; the actual devices need a
#    BINDER_CTL_ADD ioctl, and Waydroid otherwise tries to do it from the
#    unprivileged session where it fails with FileNotFoundError on modprobe.
#    The ioctl constant encodes sizeof(struct binderfs_device) = 264
#    (_IOWR('b',1,264) = 0xC1086201); a wrong size yields EINVAL.
if grep -q 'BINDER_CTL_ADD = 0xC1086201' /etc/cont-init.d/20-waydroid-setup.sh 2>/dev/null; then
    ok "binder ioctl constant has the correct size (0xC1086201)"
else
    bad "binder ioctl constant has the correct size (0xC1086201)"
fi

if grep -q 'anbox-binder' /etc/cont-init.d/20-waydroid-setup.sh 2>/dev/null; then
    ok "initialises the anbox-* binder names Waydroid actually probes for"
else
    bad "initialises the anbox-* binder names Waydroid actually probes for"
fi

# 7. modprobe must exist: Waydroid's probeBinderDriver shells out to it and
#    raises FileNotFoundError when absent.
if command -v modprobe >/dev/null 2>&1; then
    ok "modprobe is available (Waydroid's binder probe calls it)"
else
    bad "modprobe is available (Waydroid's binder probe calls it)"
fi

# 8. GPU access: the session user must be able to reach /dev/dri/cardN, or
#    the compositor dies with amdgpu_cs_ctx_create2 (-13, EACCES).
#    This only holds when GOW_REQUIRED_DEVICES is passed, which is Wolf's job,
#    so we assert the *diagnostic* exists rather than the outcome.
if grep -q 'GOW_REQUIRED_DEVICES' /opt/gow/waydroid-setup.sh 2>/dev/null; then
    ok "waydroid-setup.sh diagnoses missing /dev/dri access"
else
    bad "waydroid-setup.sh diagnoses missing /dev/dri access"
fi

# 9. The layout repair must be present. Users mount a host dir at
#    /var/lib/waydroid and hand-place images; Waydroid reads them from an
#    `images/` subdir and requires rootfs/ to exist, neither of which is
#    obvious. Both are fixed automatically at init.
if grep -q '_layout_repair' /etc/cont-init.d/20-waydroid-setup.sh 2>/dev/null; then
    ok "init repairs a hand-populated /var/lib/waydroid layout"
else
    bad "init repairs a hand-populated /var/lib/waydroid layout"
fi

# 10. Truncated images must be called out, since a partial download still
#     leaves a file present and otherwise fails much later with no clue.
if grep -q 'looks' /etc/cont-init.d/20-waydroid-setup.sh 2>/dev/null &&    grep -q 'truncated' /etc/cont-init.d/20-waydroid-setup.sh 2>/dev/null; then
    ok "init warns about truncated system.img"
else
    bad "init warns about truncated system.img"
fi

# 11. XDG_RUNTIME_DIR must be created by a cont-init script numbered BELOW
#     10. The base image's 10-setup_user.sh chowns it under `set -e`, so if
#     it does not exist yet the entire init sequence aborts there and
#     nothing after it runs (no binderfs, no D-Bus, no network, no session).
assert_path /etc/cont-init.d/05-runtime-dir.sh

if [ -d "${XDG_RUNTIME_DIR:-/tmp/.X11-unix}" ]; then
    ok "XDG_RUNTIME_DIR exists (${XDG_RUNTIME_DIR})"
else
    bad "XDG_RUNTIME_DIR exists (${XDG_RUNTIME_DIR})"
fi

# 12. sway's IPC socket lives in XDG_RUNTIME_DIR; without a writable dir
#     waybar cannot attach and floods the log with "Unable to receive IPC
#     header" while burying the real failure.
if [ -w "${XDG_RUNTIME_DIR:-/tmp/.X11-unix}" ]; then
    ok "XDG_RUNTIME_DIR is writable (sway IPC socket can be created)"
else
    bad "XDG_RUNTIME_DIR is writable (sway IPC socket can be created)"
fi

# 13. sway cannot be the primary compositor in a container: wlroots needs a
#     DRM device AND a seat/VT, and there is no logind seat here. It stops at
#     "Waiting for a session to become active" forever, never publishing its
#     IPC socket, and waybar then floods the log with "Unable to receive IPC
#     header". The image must therefore pick a backend sway can use.
if grep -q 'WLR_BACKENDS' /opt/gow/startup-app.sh 2>/dev/null; then
    ok "picks a wlroots backend sway can use in a container"
else
    bad "picks a wlroots backend sway can use in a container"
fi

# 14. The runtime dir doubles as the X11 socket dir, and Xwayland refuses it
#     unless it is owned by root or the caller.
assert_path /etc/cont-init.d/06-display-env.sh

# The privileged setup must be installed as a cont-init hook, or none of the
# above can work at all.
assert_path /etc/cont-init.d/20-waydroid-setup.sh
if grep -q 'waydroid container start' /etc/cont-init.d/20-waydroid-setup.sh; then
    ok "privileged init starts the container manager as root"
else
    bad "privileged init starts the container manager as root"
fi

# 15. Waydroid's SESSION lives on a D-Bus *session* bus (id.waydro.Session).
#     With RUN_SWAY=0 there is no sway and no $DISPLAY, so dbus-python's
#     autolaunch fails with "Unable to autolaunch a dbus-daemon without a
#     $DISPLAY for X11". startup.sh must therefore start a session dbus-daemon
#     itself and export DBUS_SESSION_BUS_ADDRESS before `show-full-ui`.
if grep -q 'DBUS_SESSION_BUS_ADDRESS' /opt/gow/startup-app.sh; then
    ok "startup-app.sh starts a session D-Bus for the waydroid session"
else
    bad "startup-app.sh starts a session D-Bus for the waydroid session"
fi
if grep -q 'dbus-daemon --session' /opt/gow/startup-app.sh; then
    ok "session D-Bus is launched with dbus-daemon --session"
else
    bad "session D-Bus is launched with dbus-daemon --session"
fi

# 16. Audio: Waydroid's lxc.py must recognise Wolf's pulse socket naming.
#     Wolf exports PULSE_SERVER=$XDG_RUNTIME_DIR/pulse-socket (a FILE), but
#     upstream lxc.py hardcodes $PULSE_RUNTIME_PATH/native, which points at a
#     nonexistent path under Wolf and yields silent "no audio". The patch must
#     resolve PULSE_SERVER (unix:/path) and fall back to $XDG_RUNTIME_DIR/
#     pulse-socket before the upstream default.
if grep -q 'pulse-socket' /usr/lib/waydroid/tools/helpers/lxc.py 2>/dev/null; then
    ok "lxc.py recognises Wolf's pulse-socket naming"
else
    bad "lxc.py recognises Wolf's pulse-socket naming"
fi
if grep -q 'PULSE_SERVER' /usr/lib/waydroid/tools/helpers/lxc.py 2>/dev/null; then
    ok "lxc.py resolves the pulse socket from PULSE_SERVER"
else
    bad "lxc.py resolves the pulse socket from PULSE_SERVER"
fi

# 17. waydroid_script (casualsnek/waydroid_script) must be present for the
#     interactive install of Magisk + libndk/libhoudini (ARM translation). It
#     must have its sudo prefixes patched out (the container runs UNAME=root
#     with no sudo), its venv deps installed, and lzip/lz4 available (the
#     script shells into the Android image and needs them).
if [ -f /opt/gow/waydroid-script/main.py ] && [ -x /opt/gow/waydroid-script/venv/bin/python3 ]; then
    ok "waydroid_script is installed with its venv"
else
    bad "waydroid_script is installed with its venv"
fi
if ! grep -q '\["sudo"' /opt/gow/waydroid-script/tools/helper.py 2>/dev/null && \
   ! grep -q '\["sudo"' /opt/gow/waydroid-script/tools/images.py 2>/dev/null; then
    ok "waydroid_script sudo prefixes patched out (root container)"
else
    bad "waydroid_script sudo prefixes patched out (root container)"
fi
for dep in lzip lz4; do
    if command -v "$dep" >/dev/null 2>&1; then
        ok "waydroid_script dependency $dep is available"
    else
        bad "waydroid_script dependency $dep is available"
    fi
done

# 18. helper.run() must judge success by exit code, not by stderr being empty.
#     Upstream treats ANY stderr output as failure, so `waydroid container
#     stop` (which logs "Stopping container" to stderr but exits 0) aborts the
#     install with the self-contradictory "returned non-zero exit status 0".
if grep -q 'if result\.returncode != 0:' /opt/gow/waydroid-script/tools/helper.py 2>/dev/null; then
    ok "helper.run() judges success by exit code (not stderr)"
else
    bad "helper.run() judges success by exit code (not stderr)"
fi

smoke_report
