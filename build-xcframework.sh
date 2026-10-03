#!/usr/bin/env bash
# Rebuilds libconvexmobile-rs.xcframework and Sources/UniFFI/convexmobile.swift from harby's
# convex-mobile fork (the Rust core), at the commit pinned below. See HARBY-PATCHES.md.
#
#   CONVEX_MOBILE_DIR=../convex-mobile ./build-xcframework.sh
#
# Requires: Xcode, rustup with the aarch64-apple-ios and aarch64-apple-ios-sim targets, and cmake
# (aws-lc-sys builds with it; e.g. `pip install cmake==3.31.6` into a venv on PATH).
set -euo pipefail

# The convex-mobile commit and Rust toolchain this checkout's XCFramework was built from.
CONVEX_MOBILE_COMMIT="${CONVEX_MOBILE_COMMIT:-ab03b313ae90284fd4e8295a4db3b1f5a7eba4ea}"
RUST_VERSION="1.95.0"

here="$(cd "$(dirname "$0")" && pwd)"
convex_mobile="$(cd "${CONVEX_MOBILE_DIR:-$here/../convex-mobile}" && pwd)"

if [[ "$(git -C "$convex_mobile" rev-parse HEAD)" != "$CONVEX_MOBILE_COMMIT" ]]; then
  echo "error: $convex_mobile is not at $CONVEX_MOBILE_COMMIT." >&2
  echo "Check that commit out, or set CONVEX_MOBILE_COMMIT when rebuilding from a new one." >&2
  exit 1
fi
if ! git -C "$convex_mobile" diff --quiet HEAD; then
  echo "error: $convex_mobile has uncommitted changes." >&2
  exit 1
fi
if [[ "$(rustc --version)" != "rustc $RUST_VERSION "* ]]; then
  echo "error: expected rustc $RUST_VERSION, found $(rustc --version). Set RUST_VERSION in this script when you upgrade." >&2
  exit 1
fi
command -v cmake >/dev/null || { echo "error: cmake is required to build aws-lc-sys." >&2; exit 1; }

# Cargo doesn't rebuild Rust crates when IPHONEOS_DEPLOYMENT_TARGET changes, so an old target directory
# can leave objects built for another minimum OS in the slices. A clean build reproduces the committed
# XCFramework byte for byte; KEEP_TARGET=1 skips it for quicker local iterations.
if [[ "${KEEP_TARGET:-0}" != "1" ]]; then
  cargo clean --manifest-path "$convex_mobile/rust/Cargo.toml"
fi

IOS_DIR="$here" "$convex_mobile/rust/build-ios.sh"

echo
echo "Slices:"
du -h "$here"/libconvexmobile-rs.xcframework/*/libconvexmobile.a
echo "Next: swift build && swift test --skip IntegrationTests, then commit the XCFramework and bindings."
