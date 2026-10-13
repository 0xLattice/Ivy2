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

# swift-crypto's manifest gives its targets a resource when the machine
# building is a Mac, whatever it builds for. SwiftPM then generates code to
# find the resource, which imports Foundation, and the module links all of
# Foundation and its ICU tables: 40 MiB that nothing calls. So on a Mac the
# copy of the manifest this build fetched, and no other, is told not to.
if [ "$(uname)" = Darwin ]; then
    IVY_CORE_ONLY=1 $SWIFT package resolve --scratch-path .build-wasm
    manifest=.build-wasm/checkouts/swift-crypto/Package.swift
    if grep -q '^#if canImport(Darwin)$' "$manifest"; then
        chmod u+w "$manifest"
        sed -i '' 's|^#if canImport(Darwin)$|#if false  // Web/build.sh: no resource in a WebAssembly build|' "$manifest"
    fi
fi

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
# The step at the top is what keeps Foundation out on a Mac. If swift-crypto
# changes the line it looks for, this says so before a page ships the result.
if LC_ALL=C grep -q -a icudt Web/dist/ivy.wasm; then
    echo "dist/ivy.wasm carries Foundation's ICU tables, 40 MiB of them: see the top of Web/build.sh" >&2
    exit 1
fi
wc -c < Web/dist/ivy.wasm | awk '{ printf "dist/ivy.wasm: %.1f MiB\n", $1 / 1048576 }'

cd Web
[ -d node_modules ] || npm ci
npm run build
