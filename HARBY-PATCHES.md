# harby's convex-swift patches

Branch `harby/0.8.1-patched` in both forks:

- `kenrick/convex-swift`, from `get-convex/convex-swift` **0.8.1** (`125b71b`);
- `kenrick/convex-mobile`, from `get-convex/convex-mobile` `720a79a`.

`720a79a` is the commit that points the `ios` submodule at 0.8.1. Its `rust/` tree is identical to `59081a7`, the commit that built 0.8.1's XCFramework. Two things in the 0.8.1 binary confirm this:
- Its `tracing` callsites (`src/lib.rs` lines 88, 205, 232, 242, 253, 279) match `59081a7`, not its parent.
- It was built with rustc 1.85.0, against convex 0.10.3, uniffi 0.28.0 and tokio 1.48.0.

Apps pin this package by revision: `.package(url: "https://github.com/kenrick/convex-swift", revision: "<sha>")`, using the tip of `harby/0.8.1-patched`. The XCFramework is committed, as it is upstream, so SwiftPM needs nothing else.

## convex-swift patches

| Commit | Patch | Upstream |
|---|---|---|
| `f91b701` | Capture `ffiClient` weakly in the token handler. A retain cycle across the FFI kept discarded clients, with their tokio runtime and websocket, alive until exit. Cherry-picked with the author kept. The PR's optional `close()` API (its commit 2) is not taken. | [PR #25](https://github.com/get-convex/convex-swift/pull/25) |
| `fd19452` | Fixes the `AuthTokenProviderBridge` use-after-free and the `authBridge` data race. See the notes below. | [#26](https://github.com/get-convex/convex-swift/issues/26), [#21](https://github.com/get-convex/convex-swift/issues/21), [convex-mobile#21](https://github.com/get-convex/convex-mobile/issues/21) |
| `42f1bbe` | Decode `$integer` / `$float` with `loadUnaligned`. `load(as:)` traps on unaligned `Data` (reproduced by `testActionRoundTrip` under TSan on 0.8.1). | none yet |
| `aefb57d` | `PrivacyInfo.xcprivacy` as a resource of the `ConvexMobile` target: File Timestamp `C617.1` for `fstat`, no tracking, no collected data. Derived from what a linked, dead-stripped app imports. | [#27](https://github.com/get-convex/convex-swift/issues/27) |
| `07af6c0` | `ConvexClient.setAdminAuth(adminKey:identity:)` plus `UserIdentity`. The XCFramework and UniFFI bindings are rebuilt from convex-mobile `ab03b31`, and `build-xcframework.sh` is added. | none (convex-rs has `set_admin_auth`) |

Notes on `fd19452`:
- One bridge per client, kept for the client's lifetime, with all auth state behind an `NSLock`.
- A session counter makes token pushes and refreshes from an ended session inert. A `logout()` during `login()` wins, and `login()` then returns `CancellationError`.
- Unchanged tokens aren't re-installed.
- `ConvexMobile` builds in Swift 6 language mode (tools 6.0; the UniFFI target and tests stay in Swift 5 mode).
- `ConvexClient` and `ConvexClientWithAuth` are `Sendable`.
- `AuthConcurrencyTests` reproduces the crash on 0.8.1: the Swift runtime aborts with "AuthTokenProviderBridge deallocated with non-zero retain count 3".

## convex-mobile patches (built into the XCFramework)

| Commit | Patch | Upstream |
|---|---|---|
| `bc99879` | Drop uniffi's `cli` feature from the library: no `uniffi_bindgen` / `cargo_metadata` in the staticlib, and 49 → 39 MB per slice. harby adaptation: the `[[bin]]` declares `required-features = ["uniffi/cli"]`, and the Android Gradle tasks pass `--features=uniffi/cli`. | [PR #23](https://github.com/get-convex/convex-mobile/pull/23) |
| `f290429` | convex-rs 0.10.3 → 0.10.4, which fixes a query-subscription memory leak. | [convex-rs#15](https://github.com/get-convex/convex-rs/issues/15) |
| `3e201e3` | Export `set_admin_auth(admin_key, acting_as_json)`. The identity JSON is parsed by convex_sync_types' own wire conversion. | none |
| `ab03b31` | `build-ios.sh` improvements, listed below. | related: [#9](https://github.com/get-convex/convex-swift/issues/9), [#10](https://github.com/get-convex/convex-swift/issues/10) |

What `ab03b31` changes in `build-ios.sh`:
- It pins the minimum OS for both Rust and C code: iOS 13.0, simulator 14.0, macOS 11.0. Unset, the C code targeted the SDK version: iOS 27 failed to link, and 0.8.1's macOS C objects need macOS 26.2.
- It remaps build paths out of the binary.
- It builds with `--locked`.
- It takes a configurable `IOS_DIR`.

## Rebuilding the XCFramework

```sh
# rustup target add aarch64-apple-ios aarch64-apple-ios-sim; cmake on PATH (aws-lc-sys needs it)
git -C ../convex-mobile checkout ab03b313ae90284fd4e8295a4db3b1f5a7eba4ea
CONVEX_MOBILE_DIR=../convex-mobile ./build-xcframework.sh
swift build && swift test --skip IntegrationTests
```

`build-xcframework.sh` refuses to run in these cases:
- the convex-mobile checkout isn't at the pinned commit (override with `CONVEX_MOBILE_COMMIT`);
- the checkout is dirty;
- rustc isn't 1.95.0.

It runs `cargo clean` first, then convex-mobile's `rust/build-ios.sh` with `IOS_DIR` set to this checkout. That writes `libconvexmobile-rs.xcframework` (slices ios-arm64, ios-arm64-simulator, macos-arm64) and `Sources/UniFFI/convexmobile.swift`.
- The clean build matters: Cargo doesn't rebuild Rust crates when the deployment target changes. `KEEP_TARGET=1` skips it for quick local iterations.
- A clean build from a different checkout path reproduces the committed libraries, headers and bindings byte for byte. Only the order of entries in the XCFramework's `Info.plist` can vary between runs.
- The Rust standard library objects come prebuilt from rustup, so they keep its iOS 10.0 minimum; everything compiled here is iOS 13.0.

`IntegrationTests` targets upstream's shared cloud test deployment, so it is skipped.

## Size

Each static slice is about 39 MB (0.8.1: 49 MB). That's archive size: the linker keeps only what an app uses.

Measured on a minimal SwiftUI app that subscribes, calls a mutation and uses `setAdminAuth` (Release, arm64 device, dead-stripped):

| | Size added | 0.8.1 for comparison |
|---|---|---|
| Executable, unstripped | 7.05 MB | |
| Executable, stripped as an archive build strips it | 5.52 MB | 5.59 MB |
| Zipped `.app` | 2.80 MB | |

The App Store encrypts the executable, so it compresses poorly. Expect the download size to land between the zipped and stripped figures.

## Rebasing onto a future upstream release

1. Fetch upstream into both clones. Rebase convex-mobile's `harby/0.8.1-patched` onto the convex-mobile commit that built the new release. Name the new branch after the release, for example `harby/0.9.0-patched`.
   - Drop any patch upstream has merged. The cherry-picks of PR #23 and PR #25 drop out by themselves if merged as-is.
   - `f290429` is redundant once upstream depends on convex ≥ 0.10.4.
   - Keep `set_admin_auth`, and the `build-ios.sh` changes unless upstream fixed the minimum OS and path remapping.
2. Rebase convex-swift's branch onto the release tag.
   - Resolve `ConvexMobile.swift` by keeping the single-bridge design from `fd19452`, unless upstream has fixed #21/#26 itself.
   - Don't carry over the old XCFramework or bindings. The `07af6c0` conflict on them resolves to whatever the rebuild produces.
3. Update `CONVEX_MOBILE_COMMIT` (and `RUST_VERSION` if the toolchain changes) in `build-xcframework.sh`.
4. Run it, then `swift build`, `swift test --skip IntegrationTests` and `swift test --sanitize=thread --skip IntegrationTests`.
5. Re-check the privacy manifest: `xcrun dyld_info -imports` on a Release app that links the package, compared against Apple's required-reason API list.
6. Commit the XCFramework and bindings. Push the branch, then re-pin the app's revision.
