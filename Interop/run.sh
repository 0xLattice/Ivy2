#!/bin/sh
# Runs Ivy 15.0.1 and this checkout against each other over real TCP, in
# every pairing. The same source builds against both, which also checks that
# the application API it uses did not change.
set -eu
cd "$(dirname "$0")"
swift build --package-path old
swift build --package-path new
OLD=old/.build/debug/node
NEW=new/.build/debug/node
port=${IVY_INTEROP_PORT:-47400}
status=0

pair() {
    listener=$1; dialer=$2; name=$3
    port=$((port + 1))
    log=$(mktemp)
    "$listener" listen 1 "$port" > "$log" 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do
        grep -q listening "$log" && break
        sleep 0.1
    done
    echo "== $name"
    if ! "$dialer" dial 2 $((port + 100)) 1 "$port"; then status=1; fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$log"
}

pair "$OLD" "$NEW" "15.0.1 listens, this checkout dials"
pair "$NEW" "$OLD" "this checkout listens, 15.0.1 dials"
pair "$NEW" "$NEW" "this checkout on both ends"
exit $status
