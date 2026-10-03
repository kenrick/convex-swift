import Foundation
import XCTest

@testable import ConvexMobile
@testable import UniFFI

/// Exercises `ConvexClientWithAuth` the way a real app and the Rust core do at the same time:
/// logins and cached logins, token pushes through `onIdToken`, logouts, and the Rust worker pulling
/// tokens through the installed `AuthTokenProvider`.
///
/// Run under the thread sanitizer (`swift test --sanitize=thread`) to catch data races on the
/// client's auth state (get-convex/convex-swift#21), which over-release the provider bridge and
/// crash in `uniffiFree` / `fetchToken` (get-convex/convex-swift#26).
final class AuthConcurrencyTests: XCTestCase {

  func testConcurrentAuthTransitionsAreRaceFree() async throws {
    let core = ThreadSafeFakeMobileConvexClient()
    let provider = ThreadSafeFakeAuthProvider()
    let client = ConvexClientWithAuth(ffiClient: core, authProvider: provider)

    await withTaskGroup(of: Void.self) { group in
      for i in 0..<300 {
        group.addTask { _ = await client.loginFromCache() }
        group.addTask { provider.pushToken("token-\(i)") }
        group.addTask { _ = try? await core.installedProvider?.fetchToken(forceRefresh: i % 3 == 0) }
        if i % 25 == 0 {
          group.addTask { await client.logout() }
          group.addTask { provider.pushToken(nil) }
        }
      }
    }

    // After the storm settles, a fresh login must leave the core with a working provider.
    _ = try await client.login().get()
    let token = try await core.installedProvider?.fetchToken(forceRefresh: false)
    XCTAssertNotNil(token)
  }

  func testTokenPushAfterLogoutDoesNotReauthenticate() async throws {
    let core = ThreadSafeFakeMobileConvexClient()
    let provider = ThreadSafeFakeAuthProvider()
    let client = ConvexClientWithAuth(ffiClient: core, authProvider: provider)

    _ = try await client.login().get()
    await client.logout()
    XCTAssertNil(core.installedProvider)

    // A provider that still holds the old onIdToken callback pushes a late refresh.
    provider.pushToken("late-token")
    try await Task.sleep(nanoseconds: 100_000_000)

    let token = try await core.installedProvider?.fetchToken(forceRefresh: false)
    XCTAssertNil(token, "a token pushed after logout must not re-authenticate the client")
  }
}

/// Stores the provider handed to `setAuthCallback` and pulls a token from it, like the Rust core.
final class ThreadSafeFakeMobileConvexClient: UniFFI.MobileConvexClientProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var provider: (any AuthTokenProvider)?

  var installedProvider: (any AuthTokenProvider)? { lock.withLock { provider } }

  func setAuthCallback(provider: (any AuthTokenProvider)?) async throws {
    lock.withLock { self.provider = provider }
    _ = try await provider?.fetchToken(forceRefresh: false)
  }

  func setAuth(token: String?) async throws {}
  func query(name: String, args: [String: String]) async throws -> String { "null" }
  func mutation(name: String, args: [String: String]) async throws -> String { "null" }
  func action(name: String, args: [String: String]) async throws -> String { "null" }
  func subscribe(name: String, args: [String: String], subscriber: any UniFFI.QuerySubscriber)
    async throws -> UniFFI.SubscriptionHandle
  {
    UniFFI.SubscriptionHandle(noPointer: UniFFI.SubscriptionHandle.NoPointer())
  }
}

/// An `AuthProvider` that, like Clerk or WorkOS SDK wrappers, keeps the latest `onIdToken`
/// callback and pushes refreshed tokens through it.
final class ThreadSafeFakeAuthProvider: AuthProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var onIdToken: (@Sendable (String?) -> Void)?
  private var counter = 0

  func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
    issue(onIdToken)
  }

  func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
    issue(onIdToken)
  }

  func logout() async throws {}

  func extractIdToken(from authResult: String) -> String { authResult }

  func pushToken(_ token: String?) {
    let callback = lock.withLock { onIdToken }
    callback?(token)
  }

  private func issue(_ callback: @Sendable @escaping (String?) -> Void) -> String {
    let token = lock.withLock {
      onIdToken = callback
      counter += 1
      return "login-\(counter)"
    }
    callback(token)
    return token
  }
}
