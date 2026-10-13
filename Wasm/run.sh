#!/bin/sh
# Builds the core for WebAssembly and checks it against the native build:
#
#   1. the core's whole test suite, compiled to Wasm and run under the
#      toolchain's Wasm runtime;
#   2. the probe, built natively and for Wasm, must print the same lines;
#   3. the core as a module (IvyWasm), driven by the JavaScript shell in
#      Web/ through its own tests, which also reach a native node
#      (IvyWebSocketTestNode) over a real WebSocket.
#
# Needs a swift.org toolchain with its matching Wasm SDK (not Xcode's), and
# Node 22 or later for steps 2 and 3. Set IVY_WASM_SDK to the SDK's id, as `swift sdk list`
# prints it. Set SWIFT to run a particular toolchain, for example
# SWIFT="swiftly run +6.4.1 swift".
set -eu
cd "$(dirname "$0")/.."
SWIFT=${SWIFT:-swift}
SDK=${IVY_WASM_SDK:?set IVY_WASM_SDK to a Wasm SDK id from 'swift sdk list'}

# Two programs here sometimes die of a signal with nothing of this package at
# fault: the toolchain's build tool while planning, and Node while it runs
# the probe, which a WebAssembly module cannot do to it (a trap is an
# exception). Those are tried again; an ordinary failure, such as a compile
# error or a wrong answer, is not.
build() {
    for attempt in 1 2 3; do
        status=0
        "$@" || status=$?
        [ "$status" -lt 128 ] && return "$status"
        echo "$1 crashed (status $status), attempt $attempt" >&2
    done
    return "$status"
}

echo "== core test suite as WebAssembly"
IVY_CORE_ONLY=1 $SWIFT test --swift-sdk "$SDK" --scratch-path .build-wasm

echo "== probe, native"
build $SWIFT build -c release --package-path Wasm/probe
native=$(find Wasm/probe/.build -type f -name probe -perm -u+x ! -path '*wasm*' | head -1)
echo "-- running $native"
"$native" > Wasm/probe/.build/native.out
cat Wasm/probe/.build/native.out

echo "== probe, WebAssembly"
build env IVY_CORE_ONLY=1 $SWIFT build -c release --swift-sdk "$SDK" --package-path Wasm/probe --scratch-path Wasm/probe/.build-wasm
wasm=$(find Wasm/probe/.build-wasm -type f -name probe.wasm | head -1)
echo "-- running $wasm under $(node --version)"
# Each attempt starts its output afresh.
probe_under_node() { node --no-warnings Wasm/run-wasi.mjs "$wasm" > Wasm/probe/.build/wasm.out; }
build probe_under_node
cat Wasm/probe/.build/wasm.out

if ! cmp -s Wasm/probe/.build/native.out Wasm/probe/.build/wasm.out; then
    echo "FAIL: the native and WebAssembly builds disagree"
    exit 1
fi
echo "PASS: the native and WebAssembly builds agree"

echo "== the module, driven from JavaScript"
SWIFT=$SWIFT IVY_WASM_SDK=$SDK Web/build.sh
build $SWIFT build --product IvyWebSocketTestNode
node=$($SWIFT build --show-bin-path)/IvyWebSocketTestNode
(cd Web && IVY_TEST_NODE=$node npm test)

size() { wc -c < "$1" | awk '{ printf "%.2f MiB", $1 / 1048576 }'; }
# Web/build.sh optimised dist/ivy.wasm already, and the tests above ran on it.
echo "ivy.wasm: $(size Web/dist/ivy.wasm), gzip $(gzip -9 -c Web/dist/ivy.wasm | wc -c | awk '{ printf "%.2f MiB", $1 / 1048576 }')"
echo "$(basename "$wasm"): $(size "$wasm")"
if command -v wasm-opt > /dev/null 2>&1; then
    wasm-opt "$wasm" --strip-debug --strip-dwarf --strip-producers -Os -o "$wasm.opt"
    echo "  optimised: $(size "$wasm.opt")"
    gzip -9 -c "$wasm.opt" > "$wasm.opt.gz"
    echo "  gzip:      $(size "$wasm.opt.gz")"
fi
