#!/bin/bash
# Interactive entry point for waydroid_script (casualsnek/waydroid_script),
# the community tool that installs Magisk, libndk (ARM translation),
# libhoudini, GApps and more into the Waydroid Android image.
#
# Usage (inside the running container):
#
#   waydroid-extras                      # interactive TUI
#   waydroid-extras install libndk       # install libndk (ARM translation)
#   waydroid-extras install magisk       # install Magisk
#   waydroid-extras uninstall magisk     # remove Magisk
#
# The payloads are downloaded at run time, so this needs network access from
# the container. The Android image must already be initialised (waydroid.cfg +
# rootfs/), and the container must be stopped for most operations -- the script
# itself stops/starts it via `waydroid container stop/start`.

set -e

SCRIPT_DIR="/opt/gow/waydroid-script"
VENV_PY="${SCRIPT_DIR}/venv/bin/python3"

if [ ! -x "$VENV_PY" ] || [ ! -f "${SCRIPT_DIR}/main.py" ]; then
    echo "waydroid_script is not installed in this image" >&2
    echo "(expected at ${SCRIPT_DIR})" >&2
    exit 1
fi

# Run as root -- the script shells into the Android container and edits
# system.img, which needs root here (UNAME=root). If someone execs as a
# non-root user, re-exec via the root entrypoint isn't available, so just warn.
if [ "$(id -u)" != "0" ]; then
    echo "waydroid-extras must run as root (this image runs UNAME=root)." >&2
    echo "Use: docker exec -u 0 <container> waydroid-extras $*" >&2
    exit 1
fi

cd "$SCRIPT_DIR"
exec "$VENV_PY" main.py "$@"
