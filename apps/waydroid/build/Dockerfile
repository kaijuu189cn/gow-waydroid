# syntax=docker/dockerfile:1.4
ARG BASE_APP_IMAGE

# hadolint ignore=DL3006
FROM ${BASE_APP_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

# Waydroid runs a full Android (LineageOS) system inside an LXC container and
# renders it through the host's Wayland compositor. In GOW terms it is just
# another GUI app sitting on top of base-app: it inherits the same
# RUN_SWAY / RUN_GAMESCOPE contract through /opt/gow/launch-comp.sh.
#
# What is genuinely different from every other app in this repo:
#   * It needs /dev/binderfs to talk to Android's binder IPC. GOW's `base`
#     image only creates the numeric device nodes listed in
#     GOW_REQUIRED_DEVICES; binderfs must be *mounted*, which requires
#     CAP_SYS_ADMIN. See scripts/startup.sh for the fallback handling.
#   * It brings its own network stack (lxcbr0-style bridge + iptables NAT),
#     because Android expects a real NIC, not the host's namespace.
#   * It runs a nested init/container manager, so it wants to be PID 1's
#     child and to keep its own cgroup/namespace layout.
#
# Packaging note: neither `waydroid` nor its Python bindings are in the
# Ubuntu archive (verified against plucky: `apt-cache search waydroid`
# returns nothing). Upstream publishes them via their own apt repo at
# repo.waydro.id, which is what we add below. Note the library package is
# called `libgbinder`, NOT `libgbinder1` -- guessing the wrong soname here
# is a hard build failure, which is how this comment came to exist.
ARG REQUIRED_PACKAGES=" \
    ca-certificates \
    curl \
    gnupg \
    lxc \
    python3 \
    python3-gi \
    python3-gi-cairo \
    gir1.2-gtk-3.0 \
    gir1.2-webkit2-4.1 \
    libglib2.0-0 \
    libglibutil \
    libgbinder \
    libhidapi-hidraw0 \
    liblxc1 \
    libnss3 \
    libxkbcommon0 \
    libx11-xcb1 \
    python3-dbus \
    python3-gbinder \
    python3-pip \
    python3-requests \
    python3-yaml \
    python3-setuptools \
    python3-wrapt \
    iptables \
    iproute2 \
    dnsmasq-base \
    nftables \
    kmod \
    lzip \
    lz4 \
    git \
    python3-venv \
    "

RUN <<_INSTALL_WAYDROID
set -e
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg

# Add the upstream Waydroid apt repository. `plucky` matches this image's
# Ubuntu 25.04 base (see images/base/build/Dockerfile). The repo is signed;
# we fetch the key over TLS and pin it to a keyring file rather than
# trusting the repo transport, matching how the firefox image adds
# Mozilla's repo.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://repo.waydro.id/waydroid.gpg \
    -o /etc/apt/keyrings/waydroid.gpg
echo "deb [signed-by=/etc/apt/keyrings/waydroid.gpg] https://repo.waydro.id/ plucky main" \
    > /etc/apt/sources.list.d/waydroid.list

apt-get update
apt-get install -y --no-install-recommends $REQUIRED_PACKAGES waydroid

apt-get autoremove -y
rm -rf /var/lib/apt/lists/*
_INSTALL_WAYDROID

# Upgrade waydroid from 1.6.2 (the newest in repo.waydro.id) to 1.6.3.
# 1.6.3 is the first release with "Initial support for Android 16 images":
# it adds the aidl5/aidl6 binder protocol mapping (tools/helpers/protocol.py)
# and the shutdown-request HIDL transaction (interfaces/IHardware.py) that the
# Android 16 (lineage-23.2) images need. repo.waydro.id has no 1.6.3 deb and
# PyPI has no waydroid package, so the source is vendored into the build
# context (waydroid-163/) and copied over the 1.6.2 install. The vendored
# tools/helpers/lxc.py already carries the GOW pulse-socket audio patch.
COPY waydroid-163/tools /usr/lib/waydroid/tools
COPY waydroid-163/data /usr/lib/waydroid/data
COPY waydroid-163/waydroid.py /usr/lib/waydroid/waydroid.py

# libgbinder 1.1.43 (the newest in repo.waydro.id) only supports up to the
# aidl4 servicemanager protocol, but Waydroid 1.6.3 selects aidl6 for Android
# 16 (API 36) images, which then fail with
#     [gbinder] WARNING: Unknown servicemanager protocol aidl6
# and "Failed to add presence handler: None", so the Android 16 container never
# comes up. aidl6 support landed in libgbinder 1.1.45 ("Add support for Android
# 16 (API level 36)"). We vendor libgbinder 1.1.52 (libgbinder-vendor/) and
# build it here, then drop the build toolchain again. Only the .so is replaced;
# python3-gbinder keeps linking against the unchanged soname libgbinder.so.1.
COPY libgbinder-vendor /tmp/libgbinder-src
RUN <<_BUILD_LIBGBINDER
set -e
apt-get update
apt-get install -y --no-install-recommends \
    build-essential pkg-config flex bison \
    libglib2.0-dev libglibutil-dev
cd /tmp/libgbinder-src
# Install into Ubuntu's multiarch lib dir (/usr/lib/x86_64-linux-gnu), not the
# default /usr/lib, so it replaces the 1.1.43 .so that apt put there.
make -j"$(nproc)" LIBDIR="usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
make install LIBDIR="usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
ldconfig
# Remove the build-only toolchain so it does not bloat the runtime image.
apt-get remove -y --auto-remove build-essential flex bison libglib2.0-dev libglibutil-dev
apt-get autoremove -y
rm -rf /var/lib/apt/lists/* /tmp/libgbinder-src
_BUILD_LIBGBINDER

# waydroid_script (casualsnek/waydroid_script) -- the community tool that
# installs Magisk, libndk (ARM translation), libhoudini, GApps etc. into the
# Android image. It is shipped IN the image (not baked) because the actual
# payloads (libndk, Magisk APK) are downloaded at run time from their upstream
# hosts, and because the user drives it INTERACTIVELY against their own
# /var/lib/waydroid (a volume). We clone a pinned revision so builds are
# reproducible, patch out the hardcoded `sudo` (this container runs as root and
# has no sudo), and install its Python deps into a venv.
ARG WAYDROID_SCRIPT_REF="main"
# waydroid_script is vendored into the build context (waydroid-script-vendor/)
# rather than cloned here. Cloning at build time is fragile: github.com is
# intermittently unreachable from build machines, and a transient TLS/connect
# failure aborts the whole image build. The vendored copy is pinned to the
# same upstream repo and the RUN step below only applies idempotent patches
# and materialises the venv (already present in the vendor dir).
COPY waydroid-script-vendor /opt/gow/waydroid-script
RUN <<_INSTALL_WAYDROID_SCRIPT
set -e
install -d -m 0755 /opt/gow
# The script invokes `sudo waydroid shell` / `sudo e2fsck` / `sudo resize2fs`.
# This container runs as UNAME=root and has no sudo, so drop the prefix.
sed -i 's/\["sudo", "waydroid"/["waydroid"/g' \
    /opt/gow/waydroid-script/tools/helper.py
sed -i 's/\["sudo", "e2fsck"/["e2fsck"/g; s/\["sudo", "resize2fs"/["resize2fs"/g' \
    /opt/gow/waydroid-script/tools/images.py
# helper.run() treats ANY stderr output as failure, even when the command
# exits 0. waydroid logs normally to stderr, so `waydroid container stop`
# succeeds but still trips this and aborts the install with a misleading
# "returned non-zero exit status 0". Judge success by the exit code instead.
sed -i 's/^    if result\.stderr:$/    if result.returncode != 0:/' \
    /opt/gow/waydroid-script/tools/helper.py
# The venv ships in the vendor dir (path matches /opt/gow/waydroid-script/venv),
# so no pip install is needed. Recreate it only if it was stripped.
if [ ! -x /opt/gow/waydroid-script/venv/bin/python3 ]; then
    python3 -m venv /opt/gow/waydroid-script/venv
    /opt/gow/waydroid-script/venv/bin/pip install --no-cache-dir \
        -r /opt/gow/waydroid-script/requirements.txt
fi
_INSTALL_WAYDROID_SCRIPT

# The Android images are large and are normally fetched on first boot by
# `waydroid init`. That is a ~1.5GB download which is a terrible first-run
# experience inside a streaming session, so bake it at build time when the
# caller opts in. Images are NOT redistributable under Waydroid's terms for
# some vendors, which is exactly why this is opt-in rather than default.
ARG WAYDROID_IMAGE_TYPE="VANILLA"
ARG WAYDROID_SYSTEM_CHANNEL=""
ARG BAKE_ANDROID_IMAGE="false"
RUN <<_BAKE_IMAGE
set -e
if [ "$BAKE_ANDROID_IMAGE" = "true" ]; then
    echo "**** Baking Android system image (type=$WAYDROID_IMAGE_TYPE) ****"
    args="-s $WAYDROID_IMAGE_TYPE"
    [ -n "$WAYDROID_SYSTEM_CHANNEL" ] && args="$args -c $WAYDROID_SYSTEM_CHANNEL"
    # `waydroid init` writes to /var/lib/waydroid; keep it out of the
    # user's home so it can be volume-mounted and shared.
    waydroid init $args
    du -sh /var/lib/waydroid || true
else
    echo "**** Skipping Android image bake (BAKE_ANDROID_IMAGE != true) ****"
    echo "**** It will be downloaded on first start via: waydroid init ****"
fi
_BAKE_IMAGE

# Waydroid's own init script expects these directories to exist and to be
# writable by the container manager even when we are not root.
RUN install -d -m 0755 /var/lib/waydroid /var/lib/waydroid/lxc /run/waydroid-lxc

# Privileged runtime setup (binderfs mount, system D-Bus, bridge + NAT) runs
# as ROOT via the cont-init.d hook, because /opt/gow/startup.sh is exec'd as
# uid 1000 by the base entrypoint and cannot do any of it. Same pattern the
# kodi image uses for its dbus daemon. See the script's header for context.
COPY overlay /

# Intel Houdini ARM translator, vendored but NOT activated.
#
# The active translator is Google's libndk_translation (0.2.3), which is what
# ships in the waydro.id Android 13 image and is what audio, online mode and
# rendering were all validated against. Houdini is kept on the image purely as
# an opt-in escape hatch: Honor of Kings SIGSEGVs in libinput's InputConsumer
# ~155s into every match, and switching the translator is the community's
# standard mitigation for this class of ARM-game crash under Waydroid.
#
# It is inert unless WAYDROID_ARM_TRANSLATOR=libhoudini is set on the app, in
# which case the init script extracts it into the Waydroid overlay and points
# ro.dalvik.vm.native.bridge at libhoudini.so.
#
# The archive is NOT committed: it is Intel proprietary code. Fetch it first
# with ./houdini/fetch-houdini.sh, which verifies this md5:
#   37fe0899f1e4da7f9a724cca1c1ab1ea
# source: github.com/supremegamers/vendor_intel_proprietary_houdini
#          commit 2f8f088671182e17e67321e098e8411a3972a628 (Android 13 / WSA 11)
#
# The COPY is of the whole directory and the check is non-fatal, so the image
# still builds without the blob -- the escape hatch is simply unavailable, and
# init section 4j logs a warning saying so.
COPY houdini/ /opt/gow/houdini/
RUN if [ -s /opt/gow/houdini/libhoudini.zip ]; then \
        echo "houdini: $(stat -c %s /opt/gow/houdini/libhoudini.zip) bytes staged"; \
    else \
        echo "houdini: ABSENT -- WAYDROID_ARM_TRANSLATOR=libhoudini will not work"; \
    fi
# Plain COPY + an explicit chmod, rather than `COPY --chmod=777`.
#
# `--chmod` is BuildKit-only. This removes one BuildKit dependency, but NOTE
# that this Dockerfile still REQUIRES BuildKit overall: the `RUN <<_INSTALL_...`
# heredoc blocks further down are BuildKit syntax too. Building without it (the
# old `DOCKER_BUILDKIT=0` legacy builder) does not merely fail -- it silently
# SKIPS those RUNs, producing an image with no /usr/bin/waydroid, which then
# dies at startup with exit 127 and shows a black screen in Moonlight. That
# exact mistake was made once; if a build seems to succeed suspiciously fast,
# verify with:
#     docker run --rm --entrypoint bash gow-waydroid:latest -c 'ls -l /usr/bin/waydroid'
COPY scripts/startup.sh /opt/gow/startup-app.sh
COPY scripts/waydroid-setup.sh /opt/gow/waydroid-setup.sh
COPY scripts/waydroid-net.sh /opt/gow/waydroid-net.sh
COPY scripts/waydroid-setting.py /opt/gow/waydroid-setting.py
COPY scripts/waydroid-extras.sh /usr/local/bin/waydroid-extras
COPY scripts/waydroid-oomguard.sh /usr/local/bin/waydroid-oomguard
COPY scripts/waydroid-apprestore.sh /usr/local/bin/waydroid-apprestore
COPY scripts/waydroid-anrwait.sh /usr/local/bin/waydroid-anrwait

# Bus-safe launchers. gow's launcher() splices the command line into a sway
# config file, where ',' is a command separator -- and a D-Bus address always
# carries a ",guid=..." suffix, which shreds the line and stops the UI from
# ever starting. These wrappers have comma-free names and recompose the address
# from the comma-free WAYDROID_BUS_EXPORT that startup.sh sets.
COPY scripts/waydroid-ui /usr/local/bin/waydroid-ui
COPY scripts/waydroid-app /usr/local/bin/waydroid-app

RUN chmod 0777 \
      /opt/gow/startup-app.sh \
      /opt/gow/waydroid-setup.sh \
      /opt/gow/waydroid-net.sh \
      /opt/gow/waydroid-setting.py \
      /usr/local/bin/waydroid-extras \
      /usr/local/bin/waydroid-oomguard \
      /usr/local/bin/waydroid-apprestore \
      /usr/local/bin/waydroid-anrwait \
      /usr/local/bin/waydroid-ui \
      /usr/local/bin/waydroid-app

# Run the session as ROOT, not `retro`.
#
# Under Wolf, XDG_RUNTIME_DIR is /run/user/wolf, a shared host directory that
# Wolf (and its root PulseAudio) owns as uid 0 with mode 0700. The Waydroid
# session must open /run/user/wolf/wayland-1 (owned by root) and, via LXC, do
# privileged mounts -- so running it as `retro` (uid 1000) makes it unable to
# even enter the runtime dir:
#
#     dbus: XDG_RUNTIME_DIR "/run/user/wolf" is owned by uid 0, not our uid 1000
#     [sway/server.c:312] Unable to open wayland socket
#
# This is the same reason gow's pulseaudio image sets UNAME=root: the app's
# data plane genuinely needs to be the same UID that owns the shared runtime
# dir. The base image's entrypoint honours UNAME and will run startup.sh via
# `gosu root` (i.e. no privilege drop), which is exactly what Waydroid needs.
ENV \
    UNAME="root" \
    XDG_RUNTIME_DIR=/tmp/.X11-unix

ARG IMAGE_SOURCE
LABEL org.opencontainers.image.source=$IMAGE_SOURCE
