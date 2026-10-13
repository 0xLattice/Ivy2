#!/bin/sh
# Builds everything Web/ runs: the core as a WebAssembly module, at
# dist/ivy.wasm, and the TypeScript beside it.
#
# Needs a swift.org toolchain with its matching Wasm SDK (not Xcode's) and
# Node 22 or later. Set IVY_WASM_SDK to the SDK's id, as `swift sdk list`
# prints it, and SWIFT to run a particular toolchain, for example
# SWIFT="swiftly run +6.4.1 swift".
set -eu
cd "$(dirname "$0")/.."
SWIFT=${SWIFT:-swift}
SDK=${IVY_WASM_SDK:?set IVY_WASM_SDK to a Wasm SDK id from 'swift sdk list'}

# The toolchain's build tool sometimes dies of a signal with none of this
# package's code running; see Wasm/run.sh. That is tried again.
for attempt in 1 2 3; do
    status=0
    IVY_CORE_ONLY=1 $SWIFT build -c release --product IvyWasm --swift-sdk "$SDK" --scratch-path .build-wasm || status=$?
    [ "$status" -lt 128 ] && break
    echo "the build tool crashed (status $status), attempt $attempt"
done
[ "$status" -eq 0 ] || exit "$status"
wasm=$(find .build-wasm -type f -name IvyWasm.wasm -path '*elease*' | head -1)
mkdir -p Web/dist
# What a page fetches: without debug information, and optimised for size.
# About 9 MiB, 3 MiB compressed, from 29 as built.
if command -v wasm-opt > /dev/null 2>&1; then
    wasm-opt "$wasm" --strip-debug --strip-dwarf --strip-producers -Os -o Web/dist/ivy.wasm
else
    echo "wasm-opt (binaryen) is not installed: dist/ivy.wasm is as built, three times the size"
    cp "$wasm" Web/dist/ivy.wasm
fi
# swift-crypto's manifest adds a resource when the machine building is a Mac,
# whatever it builds for, and the code SwiftPM generates to find it links all
# of Foundation and its ICU tables: some 40 MiB more. Built on Linux it does not.
if [ "$(uname)" = Darwin ]; then
    echo "built on macOS: dist/ivy.wasm carries Foundation and ICU; build on Linux for a page"
fi
wc -c < Web/dist/ivy.wasm | awk '{ printf "dist/ivy.wasm: %.1f MiB\n", $1 / 1048576 }'

cd Web
[ -d node_modules ] || npm ci
npm run build
