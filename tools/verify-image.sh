#!/usr/bin/env bash
# Verify a built gow-waydroid image contains what this app expects.
#
# Run after `docker build`:
#     ./tools/verify-image.sh [image]
#
# Every check below corresponds to a failure that actually happened during
# development, so a red line means a known symptom is about to come back.
set -uo pipefail

IMAGE="${1:-gow-waydroid:latest}"
pass=0; fail=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }

echo "verifying ${IMAGE}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "image not found: $IMAGE" >&2
    exit 2
fi

# Everything is checked in one container to keep it fast.
report="$(docker run --rm --entrypoint bash "$IMAGE" -c '
chk_file()  { [ -e "$1" ] && echo "OK|$2" || echo "FAIL|$2 ($1 missing)"; }
chk_exec()  { [ -x "$1" ] && echo "OK|$2" || echo "FAIL|$2 ($1 not executable)"; }
chk_grep()  { grep -q "$2" "$1" 2>/dev/null && echo "OK|$3" || echo "FAIL|$3 (pattern not in $1)"; }

# --- the failure that produced an image exiting 127 -----------------------
# A legacy-builder build silently skips the RUN heredocs, so the waydroid
# binary never lands. Nothing works without it.
chk_exec /usr/bin/waydroid "waydroid binary present (BuildKit was used)"
chk_file /usr/lib/waydroid/tools "waydroid python tools"

# --- entrypoints and helpers the app config expects ----------------------
chk_exec /opt/gow/startup-app.sh          "startup-app.sh (runner entrypoint)"
chk_exec /usr/local/bin/waydroid-ui       "waydroid-ui"
chk_exec /usr/local/bin/waydroid-app      "waydroid-app"
chk_exec /usr/local/bin/waydroid-oomguard "waydroid-oomguard"
chk_exec /usr/local/bin/waydroid-anrwait  "waydroid-anrwait"
chk_exec /usr/local/bin/waydroid-apprestore "waydroid-apprestore"

# --- init script sections that each fix a reported symptom ---------------
INIT=/etc/cont-init.d/20-waydroid-setup.sh
chk_file $INIT "init script 20-waydroid-setup.sh"
chk_grep $INIT "Single-GPU pinning"                      "4g  single-GPU pinning (花屏)"
chk_grep $INIT "gralloc.gbm.device"                      "4g  forces gralloc.gbm.device to match drm_device"
chk_grep $INIT "real audio HAL staged over the .default. stub\|real audio HAL" "4f-bis audio HAL shadowing (no audio at all)"
chk_grep $INIT "Give the guest a per-session hostname\|per-session pulse routing" "4d-bis per-session hostname (audio cross-talk)"
chk_grep $INIT "usable Wayland display\|hwcomposer"      "4i-ter hwcomposer Wayland display (black screen)"
chk_grep $INIT "radeonsi"                                "4i-bis Mesa radeonsi"
chk_grep $INIT "WAYDROID_ARM_TRANSLATOR"                 "4j  translator switch (periodic SIGSEGV)"

# The hostname override must NOT be inside the "config missing" guard, or it
# never runs on a normal start. Section 4d-bis sorts after section 4d.
gd=$(grep -n "^# 4d\. " $INIT | cut -d: -f1)
gb=$(grep -n "^# 4d-bis" $INIT | cut -d: -f1)
if [ -n "$gd" ] && [ -n "$gb" ] && [ "$gb" -gt "$gd" ]; then
    echo "OK|4d-bis is outside the missing-config guard"
else
    echo "FAIL|4d-bis placement (guard at ${gd:-?}, block at ${gb:-?})"
fi

# --- optional translator blob ------------------------------------------
if [ -s /opt/gow/houdini/libhoudini.zip ]; then
    echo "OK|houdini archive staged ($(stat -c %s /opt/gow/houdini/libhoudini.zip) bytes)"
else
    echo "WARN|houdini archive absent -- WAYDROID_ARM_TRANSLATOR=libhoudini will not work"
fi
' 2>/dev/null)"

if [ -z "$report" ]; then
    echo "could not run checks inside the image" >&2
    exit 2
fi

while IFS='|' read -r status msg; do
    case "$status" in
        OK)   ok   "$msg" ;;
        FAIL) bad  "$msg" ;;
        WARN) warn "$msg" ;;
    esac
done <<< "$report"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
