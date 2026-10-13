#!/bin/sh
# Builds the core for WebAssembly and checks it against the native build:
#
#   1. the core's whole test suite, compiled to Wasm and run under the
#      toolchain's Wasm runtime;
#   2. the probe, built natively and for Wasm, must print the same lines.
#
# Needs a swift.org toolchain with its matching Wasm SDK (not Xcode's), and
# Node for step 2. Set IVY_WASM_SDK to the SDK's id, as `swift sdk list`
# prints it. Set SWIFT to run a particular toolchain, for example
# SWIFT="swiftly run +6.4.1 swift".
set -eu
cd "$(dirname "$0")/.."
SWIFT=${SWIFT:-swift}
SDK=${IVY_WASM_SDK:?set IVY_WASM_SDK to a Wasm SDK id from 'swift sdk list'}

echo "== core test suite as WebAssembly"
IVY_CORE_ONLY=1 $SWIFT test --swift-sdk "$SDK" --scratch-path .build-wasm

echo "== probe, native"
$SWIFT build -c release --package-path Wasm/probe
native=$(find Wasm/probe/.build -type f -name probe -perm -u+x ! -path '*wasm*' | head -1)
"$native" > Wasm/probe/.build/native.out
cat Wasm/probe/.build/native.out

echo "== probe, WebAssembly"
IVY_CORE_ONLY=1 $SWIFT build -c release --swift-sdk "$SDK" --package-path Wasm/probe --scratch-path Wasm/probe/.build-wasm
wasm=$(find Wasm/probe/.build-wasm -type f -name probe.wasm | head -1)
node --no-warnings Wasm/run-wasi.mjs "$wasm" > Wasm/probe/.build/wasm.out
cat Wasm/probe/.build/wasm.out

if ! cmp -s Wasm/probe/.build/native.out Wasm/probe/.build/wasm.out; then
    echo "FAIL: the native and WebAssembly builds disagree"
    exit 1
fi
echo "PASS: the native and WebAssembly builds agree"

size() { wc -c < "$1" | awk '{ printf "%.2f MiB", $1 / 1048576 }'; }
echo "probe.wasm: $(size "$wasm")"
if command -v wasm-opt > /dev/null 2>&1; then
    wasm-opt "$wasm" --strip-debug --strip-dwarf --strip-producers -Os -o "$wasm.opt"
    echo "optimised:  $(size "$wasm.opt")"
    gzip -9 -c "$wasm.opt" > "$wasm.opt.gz"
    echo "gzip:       $(size "$wasm.opt.gz")"
fi
