#!/usr/bin/env bash
# Produce a git-apply-able patch that adds the Waydroid app to upstream gow.
#
#     ./tools/make-upstream-patch.sh [upstream-ref] [output.patch]
#
# Defaults: upstream-ref = master, output = dist/waydroid-gow.patch
#
# Why a script instead of a hand-written patch: apps/waydroid/assets/ contains
# PNGs, so the patch has to carry binary hunks. Hand-writing those is a good way
# to ship a corrupt file. This clones the real upstream, applies the change the
# same way a human would, and lets git compute the diff.
#
# It also VERIFIES the result: after generating, it resets the clone to pristine
# and runs `git apply --check`, so the artifact is known to apply before it is
# handed over.
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/games-on-whales/gow.git}"
REF="${1:-master}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${2:-${REPO_ROOT}/dist/waydroid-gow.patch}"
WORK="${WORK:-/tmp/gow-make-patch}"

[ -d "${REPO_ROOT}/apps/waydroid" ] || { echo "run from the repo: apps/waydroid not found" >&2; exit 2; }

echo "==> upstream ${UPSTREAM_URL} @ ${REF}"
rm -rf "$WORK"
git clone --depth 1 -q --branch "$REF" "$UPSTREAM_URL" "$WORK"

if [ -d "${WORK}/apps/waydroid" ]; then
    echo "    WARNING: upstream already has apps/waydroid; this patch would collide" >&2
fi

echo "==> copying apps/waydroid"
cp -a "${REPO_ROOT}/apps/waydroid" "${WORK}/apps/"

echo "==> registering the app in the CI matrices"
python3 - "${WORK}/.github/workflows/auto-build.yml" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
line_re = re.compile(r'^(\s*)- \{ name: youtube,\s+docker_path: apps,\s+platforms: "linux/amd64" \}\s*$',
                     re.M)
entry = ('          - { name: waydroid,              docker_path: apps,   '
         'platforms: "linux/amd64" }')

matches = list(line_re.finditer(src))
if len(matches) != 2:
    sys.exit(f"expected 2 'youtube' matrix lines (apps + apps-fedora), found {len(matches)}")

# Insert after each match, working backwards so earlier offsets stay valid.
for m in reversed(matches):
    src = src[:m.end()] + "\n" + entry + src[m.end():]

open(path, "w").write(src)
print(f"    inserted {len(matches)} matrix entry/entries")
PY

grep -c "name: waydroid" "${WORK}/.github/workflows/auto-build.yml" \
    | xargs -I{} echo "    confirmed {} waydroid entries in the workflow"

echo "==> committing"
git -C "$WORK" add -A
git -C "$WORK" -c user.name="waydroid-app" -c user.email="waydroid-app@localhost" \
    commit -q -F - <<'MSG'
Add Waydroid app (Android 13)

Runs a full Android 13 system (LineageOS 20 VANILLA) inside a container and
streams the Android desktop, or a single Android app, to Moonlight clients
through Wolf.

The image needs more privilege than any other app here: Waydroid is itself a
container manager, so it boots a nested Android system through LXC. That needs
SYS_ADMIN (binderfs and the nested container), NET_ADMIN (the waydroid0 bridge
and NAT rules), MKNOD (binder/ashmem device nodes), SYS_NICE (audio HAL realtime
priority) and NET_RAW. This is described in apps/waydroid/_index.md, which is
the first thing a reviewer will want.

Highlights
- No nested compositor: Waydroid renders straight into the Wayland display Wolf
  provides (RUN_SWAY=false), so there is no extra frame copy.
- Multi-GPU hosts are supported by pinning one GPU, with drm_device and
  gralloc.gbm.device derived from a single source and forced to agree.
- Audio works on this image, which requires shadowing the real HAL over the
  "default" module name because ro.hardware.audio.primary is unset.
- ARM translation defaults to libndk_translation, with Intel Houdini available
  as an opt-in alternative via WAYDROID_ARM_TRANSLATOR=libhoudini.

Also registers the app in both CI matrices (apps and apps-fedora).
MSG

mkdir -p "$(dirname "$OUT")"
echo "==> writing $OUT"
git -C "$WORK" format-patch -1 --binary --stdout > "$OUT"

echo "==> verifying the patch applies to pristine upstream"
git -C "$WORK" reset -q --hard HEAD~1
if git -C "$WORK" apply --check "$OUT"; then
    echo "    OK: applies cleanly"
else
    echo "    FAILED: patch does not apply" >&2
    exit 1
fi

echo
echo "patch:  $OUT"
echo "size:   $(stat -c %s "$OUT") bytes"
echo "files:  $(grep -c '^diff --git' "$OUT")"
echo "binary: $(grep -c '^GIT binary patch' "$OUT")"
echo
echo "To use it on a fork of gow:"
echo "    git checkout -b waydroid-app"
echo "    git am < $OUT        # or: git apply $OUT"
