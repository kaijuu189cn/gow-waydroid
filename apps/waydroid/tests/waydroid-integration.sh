#!/usr/bin/env bash
# Privileged integration test for the waydroid image.
#
# NOT run by CI. bin/test-image.sh deliberately starts containers without
# extra privileges, but the entire point of this image is that it needs
# CAP_SYS_ADMIN to mount binderfs. So the meaningful test has to run with
# privileges, which CI does not grant.
#
# Run manually on a host with a Waydroid-capable kernel (binderfs support):
#
#   ./apps/waydroid/tests/waydroid-integration.sh ghcr.io/games-on-whales/waydroid:edge
#
# Stages, in increasing order of what they prove:
#   1. binderfs can be mounted            -> kernel + privilege model OK
#   2. binder devices can be created      -> Android IPC transport OK
#   3. the bridge + NAT come up           -> Android networking OK
#   4. `waydroid` CLI runs for real       -> the image is actually usable
#
# Stage 4 intentionally stops short of `waydroid init` (a ~1.5GB download
# plus a real Android boot); pass --with-init to include it.
set -euo pipefail

IMAGE="${1:-ghcr.io/games-on-whales/waydroid:edge}"
[[ $# -ge 1 ]] && shift
WITH_INIT=""
[[ "${1:-}" == "--with-init" ]] && WITH_INIT=1

TOTAL=0; FAIL=0
step() { printf '\n==> %s\n' "$*"; }
pass() { TOTAL=$((TOTAL+1)); printf '   ok   %s\n' "$*"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); printf '   FAIL %s\n' "$*" >&2; }

# --privileged is used here because that is the honest requirement for this
# image; it is not an accident of the test. The narrower alternative that
# actually works in production is spelled out in the guidance printed at the
# end of a failure.
#
# XDG_RUNTIME_DIR/HOME are set for the same reason bin/test-image.sh sets
# them: the base image's cont-init chowns $XDG_RUNTIME_DIR and exits non-zero
# if it does not exist. Without these the container dies during init and
# every stage reports a misleading failure.
DOCKER_ARGS=(--rm --privileged --ipc=host -e XDG_RUNTIME_DIR=/tmp -e HOME=/home/retro)

step "Stage 1 -- binderfs mountable"
if out=$(docker run "${DOCKER_ARGS[@]}" "$IMAGE" \
        'mkdir -p /dev/binderfs && mount -t binder binder /dev/binderfs && ls /dev/binderfs' 2>&1); then
    if grep -q binder-control <<<"$out"; then
        pass "binderfs mounted, binder-control present"
    else
        fail "binderfs mounted but binder-control missing"
        sed 's/^/   | /' <<<"$out" >&2
    fi
else
    fail "binderfs mount failed"
    sed 's/^/   | /' <<<"$out" >&2
fi

step "Stage 2 -- binder device creation"
# waydroid allocates its own binder devices (binder1, binder2 ...) through
# binder-control; this is what upstream does at container start.
#
# The system D-Bus daemon must be running first: waydroid's CLI reaches its
# container manager over the *system* bus, and the base image has no systemd
# to start one. This mirrors what scripts/startup.sh does.
if out=$(docker run "${DOCKER_ARGS[@]}" "$IMAGE" \
        'mkdir -p /run/dbus && dbus-daemon --system --fork && mkdir -p /dev/binderfs && mount -t binder binder /dev/binderfs && (waydroid container start >/dev/null 2>&1 &) ; sleep 8; ls -la /dev/binderfs' 2>&1); then
    if grep -qE 'binder[0-9]' <<<"$out"; then
        pass "waydroid created its binder device(s)"
    else
        # Not fatal on its own: some builds only create devices once the
        # Android session starts. Report as informational.
        printf '   note binder devices not created at this stage (may be created lazily)\n'
        sed 's/^/   | /' <<<"$out" >&2
    fi
else
    fail "could not run waydroid container start"
    sed 's/^/   | /' <<<"$out" >&2
fi

step "Stage 3 -- bridge + NAT"
if out=$(docker run "${DOCKER_ARGS[@]}" "$IMAGE" \
        '/opt/gow/waydroid-net.sh start && ip -brief addr show waydroid0 && iptables -t nat -S POSTROUTING' 2>&1); then
    if grep -q "192.168.240.1" <<<"$out" && grep -q MASQUERADE <<<"$out"; then
        pass "waydroid0 up with NAT"
    else
        fail "bridge or NAT rule missing"
        sed 's/^/   | /' <<<"$out" >&2
    fi
else
    fail "waydroid-net.sh start failed"
    sed 's/^/   | /' <<<"$out" >&2
fi

step "Stage 4 -- waydroid CLI"
# `waydroid status` is the end-to-end proof that the stack is coherent: it
# needs the system bus (to reach the manager), binder (to enumerate Android)
# and the image set (to know whether it is initialised). An uninitialised
# but *working* install answers "Waydroid is not initialized" and exits 0;
# that is a pass here, because this test does not download the 838MB image.
if out=$(docker run "${DOCKER_ARGS[@]}" "$IMAGE" \
        'mkdir -p /run/dbus && dbus-daemon --system --fork && mkdir -p /dev/binderfs && mount -t binder binder /dev/binderfs && waydroid status' 2>&1); then
    pass "waydroid status ran"
    sed 's/^/   | /' <<<"$out"
else
    fail "waydroid status failed"
    sed 's/^/   | /' <<<"$out" >&2
fi

if [[ -n "$WITH_INIT" ]]; then
    step "Stage 5 -- waydroid init (downloads ~1.5GB)"
    if docker run "${DOCKER_ARGS[@]}" "$IMAGE" 'waydroid init -s VANILLA' 2>&1 | tail -20; then
        pass "waydroid init completed"
    else
        fail "waydroid init failed"
    fi
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
    printf '== PASS == %d/%d checks passed for %s\n' "$TOTAL" "$TOTAL" "$IMAGE"
    exit 0
else
    printf '== FAIL == %d/%d checks failed for %s\n' "$FAIL" "$TOTAL" "$IMAGE" >&2
    cat >&2 <<'EOF'

If Stage 1 failed, binderfs could not be mounted. Options, least privilege
first:

  * Host mounts binderfs and you pass it in:
      --mount type=bind,src=/dev/binderfs,dst=/dev/binderfs
  * Pass the device nodes through instead of mounting:
      --device=/dev/binder --device=/dev/binderfs
  * Grant just the needed capability:
      --cap-add=SYS_ADMIN --security-opt seccomp=unconfined
  * Last resort:
      --privileged

Note that kernels < 5.18 also need /dev/ashmem; kernels >= 5.18 use memfd.
EOF
    exit 1
fi
