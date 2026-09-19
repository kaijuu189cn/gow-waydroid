#!/bin/bash
# Bring up the Waydroid bridge + NAT inside this container.
#
# Waydroid upstream ships data/scripts/waydroid-net.sh, which is an LXC
# helper invoked by the lxc hook system with `$1 = start|stop`. It assumes
# it owns the host's networking and that it is the only thing configuring
# the bridge. Inside a GOW container that assumption is *nearly* safe (we
# have our own netns) but two things differ, and both are handled here:
#
#   * There is no systemd, so nothing calls this on boot. startup.sh runs it.
#   * `dnsmasq` is started by upstream as a long-lived helper; we must not
#     block on it, and we must be idempotent because a container can be
#     restarted without being recreated.
#
# This wrapper deliberately only implements the subset Waydroid actually
# needs for a single Android instance.
set -e

source /opt/gow/bash-lib/utils.sh

LXC_BRIDGE="${WAYDROID_BRIDGE:-waydroid0}"
LXC_ADDR="192.168.240.1"
LXC_NETMASK="255.255.255.0"
LXC_NETWORK="192.168.240.0/24"
LXC_DHCP_RANGE_START="192.168.240.2"
LXC_DHCP_RANGE_END="192.168.240.254"

ACTION="${1:-start}"

# Prefer the nft-backed `iptables`. Upstream's waydroid-net.sh prefers
# `iptables-legacy`, but that is the wrong default inside a container: on
# kernels built without the legacy nat table (very common with modern
# distro kernels, and the case on the kernel this image was tested against)
# `iptables-legacy -t nat` fails with "Table does not exist", while the nft
# backend works. Waydroid itself only needs *a* working nat table, so we
# take whichever one actually resolves.
IPTABLES_BIN=""
for cand in iptables iptables-nft iptables-legacy; do
    bin="$(command -v "$cand" 2>/dev/null || true)"
    [ -z "$bin" ] && continue
    if "$bin" -t nat -L -n >/dev/null 2>&1; then
        IPTABLES_BIN="$bin"
        break
    fi
done
if [ -n "$IPTABLES_BIN" ]; then
    gow_log "[net] Using iptables binary: ${IPTABLES_BIN}"
else
    gow_log "[net] WARNING: no iptables binary with a usable nat table"
fi

start_network() {
    gow_log "[net] Configuring ${LXC_BRIDGE} (${LXC_ADDR}/24)"

    # Idempotent: a restarted container keeps the bridge, a recreated one
    # does not. `ip link add` fails if it already exists, so probe first.
    if ! ip link show "$LXC_BRIDGE" >/dev/null 2>&1; then
        ip link add name "$LXC_BRIDGE" type bridge
        gow_log "[net] Created bridge ${LXC_BRIDGE}"
    else
        gow_log "[net] Bridge ${LXC_BRIDGE} already exists"
    fi

    if ! ip addr show "$LXC_BRIDGE" | grep -q "${LXC_ADDR}/24"; then
        ip addr add "${LXC_ADDR}/24" dev "$LXC_BRIDGE"
    fi
    ip link set "$LXC_BRIDGE" up

    # Android needs to reach the outside world. Route through the
    # container's default interface, which in a Wolf runner is the one
    # Docker/Wolf gave us.
    sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || \
        gow_log "[net] WARNING: could not set ip_forward (may already be 1)"

    if [ -n "$IPTABLES_BIN" ]; then
        # Guard every rule so repeated starts do not stack MASQUERADE
        # entries (which would be harmless but makes the ruleset unreadable).
        if ! $IPTABLES_BIN -t nat -C POSTROUTING -s "$LXC_NETWORK" -j MASQUERADE 2>/dev/null; then
            $IPTABLES_BIN -t nat -A POSTROUTING -s "$LXC_NETWORK" -j MASQUERADE
            gow_log "[net] Added MASQUERADE for ${LXC_NETWORK}"
        fi
        if ! $IPTABLES_BIN -C FORWARD -i "$LXC_BRIDGE" -j ACCEPT 2>/dev/null; then
            $IPTABLES_BIN -A FORWARD -i "$LXC_BRIDGE" -j ACCEPT
        fi
        if ! $IPTABLES_BIN -C FORWARD -o "$LXC_BRIDGE" -j ACCEPT 2>/dev/null; then
            $IPTABLES_BIN -A FORWARD -o "$LXC_BRIDGE" -j ACCEPT
        fi
    else
        gow_log "[net] WARNING: no iptables binary; Android will have no outbound NAT"
    fi
}

stop_network() {
    gow_log "[net] Tearing down ${LXC_BRIDGE}"
    if [ -n "$IPTABLES_BIN" ]; then
        $IPTABLES_BIN -t nat -D POSTROUTING -s "$LXC_NETWORK" -j MASQUERADE 2>/dev/null || true
        $IPTABLES_BIN -D FORWARD -i "$LXC_BRIDGE" -j ACCEPT 2>/dev/null || true
        $IPTABLES_BIN -D FORWARD -o "$LXC_BRIDGE" -j ACCEPT 2>/dev/null || true
    fi
    ip link set "$LXC_BRIDGE" down 2>/dev/null || true
    ip link del "$LXC_BRIDGE" 2>/dev/null || true
}

case "$ACTION" in
    start) start_network ;;
    stop)  stop_network ;;
    *)     gow_log "[net] usage: $0 start|stop"; exit 1 ;;
esac

gow_log "[net] DONE"
