#!/usr/bin/env bash
# Fetch the Intel Houdini ARM translator used by the optional
# WAYDROID_ARM_TRANSLATOR=libhoudini escape hatch.
#
# Why this is a script and not a committed file: Houdini is Intel proprietary
# code. This repository does not redistribute it; it downloads the same archive
# that casualsnek/waydroid_script uses and verifies the checksum.
#
# The image builds fine without it -- section 4j of 20-waydroid-setup.sh just
# logs a warning when the archive is missing.
set -euo pipefail

URL="https://github.com/supremegamers/vendor_intel_proprietary_houdini/archive/2f8f088671182e17e67321e098e8411a3972a628.zip"
# Expected md5, matching stuff/houdini.py in waydroid_script for Android 13.
MD5="37fe0899f1e4da7f9a724cca1c1ab1ea"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${DIR}/libhoudini.zip"

if [ -s "$OUT" ] && [ "$(md5sum "$OUT" | cut -d' ' -f1)" = "$MD5" ]; then
    echo "already present and verified: $OUT"
    exit 0
fi

echo "downloading Houdini (~72 MB; codeload does not support resume, so this is"
echo "a single full download and can take a while on a slow link)..."
# No -C: GitHub's codeload rejects byte ranges ("HTTP server doesn't seem to
# support byte ranges"), so a partial file must be discarded, not resumed.
rm -f "$OUT"
curl -fL --retry 3 --retry-delay 5 -o "$OUT" "$URL"

got="$(md5sum "$OUT" | cut -d' ' -f1)"
if [ "$got" != "$MD5" ]; then
    echo "ERROR: md5 mismatch" >&2
    echo "  expected $MD5" >&2
    echo "  got      $got" >&2
    rm -f "$OUT"
    exit 1
fi

echo "ok: $OUT ($(stat -c %s "$OUT") bytes, md5 $got)"
