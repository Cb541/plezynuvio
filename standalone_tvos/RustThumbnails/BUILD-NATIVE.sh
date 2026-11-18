#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/native"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Requires macOS and Xcode with the Apple TV device SDK.' >&2; exit 1
fi
command -v rustup >/dev/null
export SDKROOT="$(xcrun --sdk appletvos --show-sdk-path)"
export TVOS_DEPLOYMENT_TARGET="17.0"
export CARGO_TARGET_AARCH64_APPLE_TVOS_LINKER="$(xcrun --sdk appletvos --find clang)"
export CC_aarch64_apple_tvos="$CARGO_TARGET_AARCH64_APPLE_TVOS_LINKER"
export AR_aarch64_apple_tvos="$(xcrun --sdk appletvos --find ar)"
export CFLAGS_aarch64_apple_tvos="-isysroot $SDKROOT -mtvos-version-min=17.0"
rustup toolchain install nightly --component rust-src
cargo +nightly build -Z build-std=std,panic_abort --target aarch64-apple-tvos --release -p nuvio-tvos-thumbnails --lib
printf '\nStatic library: %s\n' "$PWD/target/aarch64-apple-tvos/release/libnuvio_tvos_thumbnails.a"
