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

IVY_CORE_ONLY=1 $SWIFT build -c release --product IvyWasm --swift-sdk "$SDK" --scratch-path .build-wasm
wasm=$(find .build-wasm -type f -name IvyWasm.wasm -path '*elease*' | head -1)
mkdir -p Web/dist
cp "$wasm" Web/dist/ivy.wasm

cd Web
[ -d node_modules ] || npm ci
npm run build
