#!/bin/sh
# Two nodes behind NATs of their own meet through a carrier and connect to
# each other directly.
#
# Linux, as root, with iproute2 and iptables: it builds a small internet out
# of network namespaces.
#
#   ha (192.168.1.2) -- na: NAT (11.0.1.2) --+
#                                             +-- c: the carrier, and the route between
#   hb (192.168.2.2) -- nb: NAT (11.0.2.2) --+
#
# Neither node can be dialled: each NAT forwards only what answers something
# sent from inside, which is checked first. Three NATs are tried:
#
#   drop    drops what it did not ask for, and keeps a connection's port.
#   reset   as drop, but answers what it did not ask for with a reset.
#   random  gives every connection a port of its own choosing. The port a
#           node tells its peer is then not the one it is reached at, so the
#           two are expected to stay on the relayed session.
#
# IVY_PUNCH_NODE is a built IvyPunchTestNode; without it one is built here.
set -eu
cd "$(dirname "$0")/.."
node=${IVY_PUNCH_NODE:-}
if [ -z "$node" ]; then
    swift build --product IvyPunchTestNode
    node=$(swift build --show-bin-path)/IvyPunchTestNode
fi

out=$(mktemp -d)
spaces="c na nb ha hb"
pids=""

clean() {
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    pids=""
    for space in $spaces; do ip netns del "ivy-$space" 2>/dev/null || true; done
}
trap 'clean; rm -rf "$out"' EXIT

in_space() { space=$1; shift; ip netns exec "ivy-$space" "$@"; }

# link <space> <address> <space> <address>: a cable between two namespaces.
link() {
    ip link add "$1-$3" netns "ivy-$1" type veth peer name "$3-$1" netns "ivy-$3"
    in_space "$1" ip addr add "$2" dev "$1-$3"
    in_space "$3" ip addr add "$4" dev "$3-$1"
    in_space "$1" ip link set "$1-$3" up
    in_space "$3" ip link set "$3-$1" up
}

# nat <space> <kind>: forwards what answers something sent from inside.
nat() {
    outside="$1-c"
    in_space "$1" sysctl -qw net.ipv4.ip_forward=1
    if [ "$2" = random ]; then
        in_space "$1" iptables -t nat -A POSTROUTING -o "$outside" -j MASQUERADE --random-fully
    else
        in_space "$1" iptables -t nat -A POSTROUTING -o "$outside" -j MASQUERADE
    fi
    in_space "$1" iptables -A FORWARD -i "$outside" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    in_space "$1" iptables -A INPUT -i "$outside" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    for chain in FORWARD INPUT; do
        if [ "$2" = reset ]; then
            in_space "$1" iptables -A "$chain" -i "$outside" -p tcp -j REJECT --reject-with tcp-reset
        fi
        in_space "$1" iptables -A "$chain" -i "$outside" -j DROP
    done
    # A path across the internet takes time, which is what lets two first
    # packets cross. Left out where the kernel cannot delay.
    in_space "$1" tc qdisc add dev "$outside" root netem delay 15ms 2>/dev/null || true
}

# network <NAT of a> <NAT of b>
network() {
    clean
    for space in $spaces; do
        ip netns add "ivy-$space"
        in_space "$space" ip link set lo up
    done
    link c 11.0.1.1/24 na 11.0.1.2/24
    link c 11.0.2.1/24 nb 11.0.2.2/24
    link na 192.168.1.1/24 ha 192.168.1.2/24
    link nb 192.168.2.1/24 hb 192.168.2.2/24
    in_space c sysctl -qw net.ipv4.ip_forward=1
    in_space na ip route add default via 11.0.1.1
    in_space nb ip route add default via 11.0.2.1
    in_space ha ip route add default via 192.168.1.1
    in_space hb ip route add default via 192.168.2.1
    nat na "$1"
    nat nb "$2"
}

seed() { printf "%064d" "$1"; }

# key <file>: the public key a node printed when it started.
key() {
    for _ in $(seq 100); do
        value=$(awk '$1 == "carrier" || $1 == "peer" { print $2; exit }' "$1" 2>/dev/null || true)
        [ -n "$value" ] && { echo "$value"; return; }
        sleep 0.1
    done
    echo "no key in $1" >&2
    cat "$1" >&2
    exit 1
}

# scenario <name> <NAT of a> <NAT of b> <DIRECT|RELAYED>
scenario() {
    echo "== $1: expecting $4"
    network "$2" "$3"
    rm -f "$out"/*

    in_space c sh -c "sleep 120 | '$node' carrier $(seed 1)" > "$out/c" 2>&1 &
    pids="$pids $!"
    carrier=$(key "$out/c")

    in_space ha "$node" peer "$(seed 2)" "$carrier@11.0.1.1:4001" 11.0.1.2 > "$out/a" 2>&1 &
    a=$!
    pids="$pids $a"
    a_key=$(key "$out/a")

    # The carrier can be dialled from behind a NAT, so the check below can fail.
    if ! in_space hb timeout 2 bash -c "exec 3<>/dev/tcp/11.0.2.1/4001" 2>/dev/null; then
        echo "FAIL: the carrier cannot be dialled"
        exit 1
    fi
    # Neither NAT lets a stranger in: b cannot dial a's listener, by either address.
    for address in 11.0.1.2 192.168.1.2; do
        if in_space hb timeout 2 bash -c "exec 3<>/dev/tcp/$address/4001" 2>/dev/null; then
            echo "FAIL: $address:4001 can be dialled from behind the other NAT"
            exit 1
        fi
    done

    in_space hb "$node" peer "$(seed 3)" "$carrier@11.0.2.1:4001" 11.0.2.2 "$a_key" > "$out/b" 2>&1 &
    b=$!
    pids="$pids $b"

    wait "$a" || true
    wait "$b" || true
    sed 's/^/   a: /' "$out/a"
    sed 's/^/   b: /' "$out/b"
    for end in a b; do
        if ! grep -qx "$4" "$out/$end"; then
            echo "FAIL: $1: $end did not end $4"
            exit 1
        fi
        # Whatever became of the attempt, the session never dropped on the
        # way there. (The other node stopping, afterwards, is a disconnect.)
        if sed "/^$4\$/q" "$out/$end" | grep -q "^disconnected"; then
            echo "FAIL: $1: $end heard a disconnect"
            exit 1
        fi
    done
}

scenario "two NATs that drop" drop drop DIRECT
scenario "two NATs that reset" reset reset DIRECT
scenario "one NAT that resets" drop reset DIRECT
scenario "a NAT that changes ports" drop random RELAYED
clean
echo "PASS"
