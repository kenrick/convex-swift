// The Swift Programming Language
// https://docs.swift.org/swift-book

import Combine
import Foundation
@_exported import UniFFI

/// A client API for interacting with a Convex backend.
///
/// Handles marshalling of data between calling code and the
/// [convex-mobile](https://github.com/get-convex/convex-mobile) and
/// [convex-rs](https://github.com/get-convex/convex-rs) native libraries.
///
/// Consumers of this client should use Swift's ``Decodable``  protocol for handling data received from the
/// Convex backend.
///
/// A client is safe to share across threads and actors: its own state is immutable and the
/// underlying Rust client is thread-safe.
public class ConvexClient: @unchecked Sendable {
  let ffiClient: UniFFI.MobileConvexClientProtocol
  fileprivate let webSocketStateAdapter = WebSocketStateAdapter()

  /// Creates a new instance of ``ConvexClient``.
  ///
  /// - Parameters:
  ///   - deploymentUrl: The Convex backend URL to connect to; find it in the [dashboard](https://dashboard.convex.dev) Settings for your project
  public init(deploymentUrl: String) {
    self.ffiClient = UniFFI.MobileConvexClient(
      deploymentUrl: deploymentUrl, clientId: "swift-\(convexMobileVersion)", webSocketStateSubscriber: webSocketStateAdapter)
  }

  init(ffiClient: UniFFI.MobileConvexClientProtocol) {
    self.ffiClient = ffiClient
  }

  /// Subscribes to the query with the given `name` and converts data from the subscription into an
  /// ``AnyPublisher<T, ClientError>``.
  ///
  /// The upstream Convex subscription will be canceled if whatever is subscribed to returned publisher
  /// stops listening.
  ///
  /// - Parameters:
  ///   - name: A value in "module:query_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend query function
  ///   - output: The type of data that will be returned in the Publisher, as a convenience to callers
  ///             where the type can't be easily inferred.
  public func subscribe<T: Decodable>(
    to name: String, with args: [String: ConvexEncodable?]? = nil, yielding output: T.Type? = nil
  ) -> AnyPublisher<T, ClientError> {
    // There are two steps to producing the final Publisher in this method.
    // 1. Subscribe to the data from Convex and publish the subscription handle
    // 2. Feed the subscription handle into the Convex data Publisher so it can cancel the upstream
    //    subscription when downstream subscribers are done consuming data

    // This Publisher will ultimately publish the data received from Convex.
    let convexPublisher = PassthroughSubject<T, ClientError>()
    let subscriber: any QuerySubscriber & Sendable = SubscriptionAdapter<T>(publisher: convexPublisher)

    // This Publisher is responsible for initializing the Convex subscription and returning a handle
    // to the upstream (Convex) subscription.
    let initializationPublisher = Future<SubscriptionHandle, ClientError> {
      result in
      let encodedArgs: [String: String]
      do {
        encodedArgs = try args?.mapValues({ v in try v?.convexEncode() ?? "null" }) ?? [:]
      } catch {
        result(.failure(ClientError.InternalError(msg: error.localizedDescription)))
        return
      }
      // `Future` guards its promise with a lock, so it may be fulfilled from the task.
      nonisolated(unsafe) let result = result
      Task {
        do {
          let subscriptionHandle = try await self.ffiClient.subscribe(
            name: name, args: encodedArgs, subscriber: subscriber)
          result(.success(subscriptionHandle))
        } catch {
          result(.failure(ClientError.InternalError(msg: error.localizedDescription)))
        }
      }
    }

    // The final Publisher takes the handle from the initial Convex subscription and supplies it to
    // the data publisher so it can cancel the upstream subscription when consumers are no longer
    // listening for data.
    return initializationPublisher.flatMap({ subscriptionHandle in
      convexPublisher.handleEvents(receiveCancel: {
        subscriptionHandle.cancel()
      })
    })
    .eraseToAnyPublisher()
  }

  /// Executes the mutation with the given `name` and `args` and returns the result.
  ///
  /// For mutations that don't return a value, prefer calling the version of this method that doesn't return a value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func mutation<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws -> T
  {
    try await callForResult(name: name, args: args, remoteCall: ffiClient.mutation)
  }

  /// Executes the mutation with the given `name` and `args` without returning a result.
  ///
  /// For mutations that return a value, prefer calling the version of this method that returns a ``Decodable`` value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func mutation(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws
  {
    let _: String? = try await mutation(name, with: args)
  }

  /// Executes the action with the given `name` and `args` and returns the result.
  ///
  /// For actions that don't return a value, prefer calling the version of this method that doesn't return a value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func action<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws -> T
  {
    return try await callForResult(name: name, args: args, remoteCall: ffiClient.action)
  }

  /// Executes the action with the given `name` and `args` without returning a result.
  ///
  /// For actions that return a value, prefer calling the version of this method that returns a ``Decodable`` value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func action(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws
  {
    let _: String? = try await action(name, with: args)
  }

  /// Common handler for `action` and `mutation` calls.
  ///
  /// To the client code, both work in a very similar fashion where remote code is invoked and a result is returned. This handler takes care of
  /// encoding the arguments and decoding the result, whether the call is an `action` or `mutation`.
  func callForResult<T: Decodable>(
    name: String, args: [String: ConvexEncodable?]? = nil, remoteCall: RemoteCall
  )
    async throws -> T
  {
    let rawResult = try await remoteCall(
      name,
      args?.mapValues({ v in
        try v?.convexEncode() ?? "null"
      }) ?? [:])
    return try JSONDecoder().decode(T.self, from: Data(rawResult.utf8))
  }

  typealias RemoteCall = (String, [String: String]) async throws -> String
  
  public func watchWebSocketState() -> AnyPublisher<WebSocketState, Never> {
    return webSocketStateAdapter.newPublisher()
  }
}

/// Authentication states that can be experienced when using an ``AuthProvider`` with
/// ``ConvexClientWithAuth``.
public enum AuthState<T> {
  /// Represents an authenticated user.
  ///
  /// Contains authentication data from the associated ``AuthProvider``.
  case authenticated(T)
  /// Represents an unauthenticated user.
  case unauthenticated
  /// Represents an ongoing authentication attempt.
  case loading
}

/// An authentication provider, used with ``ConvexClientWithAuth``.
///
/// The generic type `T` is the data returned by the provider upon a successful authentication attempt.
///
/// The client calls these methods from arbitrary threads, sometimes concurrently (for example a
/// token refresh requested by the Rust client while ``ConvexClientWithAuth/login()`` runs), so
/// implementations must be thread-safe.
public protocol AuthProvider<T> {
  associatedtype T

  /// Trigger a login flow, which might launch a new UI/screen.
  ///
  /// - Parameter onIdToken: A callback to invoke with a fresh JWT ID token. The auth provider should store
  ///   this callback and invoke it whenever a new token is available (e.g., on token refresh).
  ///   Call with `nil` if the session becomes invalid (e.g., token refresh fails).
  func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> T

  /// Trigger a logout flow, which might launch a new UI/screen.
  func logout() async throws

  /// Trigger a cached, UI-less re-authentication using stored credentials from a previous ``login()``.
  ///
  /// For OAuth providers, this is a good place to check token validity and perform a refresh if necessary
  /// before returning the auth data as``T``.
  ///
  /// - Parameter onIdToken: A callback to invoke with a fresh JWT ID token. The auth provider should store
  ///   this callback and invoke it whenever a new token is available (e.g., on token refresh).
  ///   Call with `nil` if the session becomes invalid (e.g., token refresh fails).
  func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void)
    async throws -> T

  /// Extracts a [JWT ID token](https://openid.net/specs/openid-connect-core-1_0.html#IDToken)
  /// from the `authResult`.
  func extractIdToken(from authResult: T) -> String
}

/// The ``AuthTokenProvider`` that a ``ConvexClientWithAuth`` hands to the Rust client, adapting the
/// push-based `onIdToken` model to the Rust client's pull-based token callback.
///
/// A client creates exactly one bridge and keeps it for its whole lifetime, so the object the Rust
/// client calls into is never replaced or released while a call is in flight
/// (get-convex/convex-swift#26). All mutable state is guarded by `lock`, because the Rust worker,
/// token pushes and the client's own methods reach it from different threads
/// (get-convex/convex-swift#21).
private final class AuthTokenProviderBridge: AuthTokenProvider, @unchecked Sendable {
  typealias Refresh = @Sendable (_ session: UInt64) async throws -> String?

  private let lock = NSLock()
  /// The token handed to the Rust client, or `nil` when no session is active.
  private var token: String?
  /// Incremented whenever a session ends, so token callbacks and logins that belong to an
  /// earlier session can be told apart from current ones and ignored.
  private var session: UInt64 = 0
  private var refresh: Refresh?

  var currentSession: UInt64 { lock.withLock { session } }

  func setRefresh(_ refresh: @escaping Refresh) {
    lock.withLock { self.refresh = refresh }
  }

  /// Starts or continues `session` with `token`. Returns `false` if `session` has ended.
  func activate(token: String, session: UInt64) -> Bool {
    lock.withLock {
      guard self.session == session else { return false }
      self.token = token
      return true
    }
  }

  /// Replaces the token of `session` if it is still active. Returns `true` only if the token
  /// changed, so a late refresh can never start a session on its own and a token the Rust client
  /// already has (for example one it just pulled through ``fetchToken(forceRefresh:)``) isn't
  /// pushed again.
  func update(token: String, session: UInt64) -> Bool {
    lock.withLock {
      guard self.session == session, let current = self.token, current != token else {
        return false
      }
      self.token = token
      return true
    }
  }

  /// Ends the current session, or only `session` when given. Returns `false` if `session` had
  /// already ended.
  @discardableResult
  func endSession(_ session: UInt64? = nil) -> Bool {
    lock.withLock {
      if let session, session != self.session { return false }
      self.session &+= 1
      token = nil
      return true
    }
  }

  func fetchToken(forceRefresh: Bool) async throws -> String? {
    let (cached, session, refresh) = lock.withLock { (token, self.session, self.refresh) }
    guard let cached else { return nil }
    // It's not required to treat this as a "force refresh": `refresh` only has to return a
    // valid token, which can be one the `AuthProvider` cached earlier.
    guard forceRefresh, let refresh, let fresh = try? await refresh(session) else {
      return cached
    }
    return lock.withLock {
      // A logout while the refresh was in flight wins over the refreshed token.
      guard self.session == session, token != nil else { return nil }
      token = fresh
      return fresh
    }
  }
}

/// Like ``ConvexClient``, but supports integration with an authentication provider via ``AuthProvider``.
///
/// The generic parameter `T` matches the type of data returned by the ``AuthProvider`` upon successful
/// authentication.
public class ConvexClientWithAuth<T>: ConvexClient, @unchecked Sendable {
  private let authPublisher = CurrentValueSubject<AuthState<T>, Never>(AuthState.unauthenticated)
  private let authProvider: any AuthProvider<T>
  private let authBridge = AuthTokenProviderBridge()

  /// A publisher that updates with the current ``AuthState`` of this client instance.
  public let authState: AnyPublisher<AuthState<T>, Never>

  /// Creates a new instance of ``ConvexClientWithAuth``.
  ///
  /// - Parameters:
  ///   - deploymentUrl: The Convex backend URL to connect to; find it in the [dashboard](https://dashboard.convex.dev) Settings for your project
  ///   - authProvider: An instance that will handle the actual authentication duties.
  public init(deploymentUrl: String, authProvider: any AuthProvider<T>) {
    self.authProvider = authProvider
    self.authState = authPublisher.eraseToAnyPublisher()
    super.init(deploymentUrl: deploymentUrl)
    installRefresh()
  }

  init(ffiClient: MobileConvexClientProtocol, authProvider: any AuthProvider<T>) {
    self.authProvider = authProvider
    self.authState = authPublisher.eraseToAnyPublisher()
    super.init(ffiClient: ffiClient)
    installRefresh()
  }

  /// Triggers a UI driven login flow and updates the ``authState``.
  ///
  /// The ``authState`` is set to ``AuthState.loading`` immediately upon calling this method and
  /// will change to either ``AuthState.authenticated`` or ``AuthState.unauthenticated``
  /// depending on the result. A ``logout()`` that completes while the login flow is still
  /// running wins: the login then fails with `CancellationError` and leaves the client logged out.
  public func login() async -> Result<T, Error> {
    await login(strategy: authProvider.login)
  }

  /// Triggers a cached, UI-less re-authentication flow using previously stored credentials and updates the
  /// ``authState``.
  ///
  /// If no credentials were previously stored, or if there is an error reusing stored credentials, the resulting
  /// ``authState`` willl be ``AuthState.unauthenticated``. If supported by the ``AuthProvider``,
  /// a call to ``login()`` should store another set of credentials upon successful authentication.
  ///
  /// The ``authState`` is set to ``AuthState.loading`` immediately upon calling this method and
  /// will change to either ``AuthState.authenticated`` or ``AuthState.unauthenticated``
  /// depending on the result.
  public func loginFromCache() async -> Result<T, Error> {
    await login(strategy: authProvider.loginFromCache)
  }

  /// Triggers a logout flow and updates the ``authState``.
  ///
  /// The ``authState`` will change to ``AuthState.unauthenticated`` if logout is successful.
  /// Tokens the ``AuthProvider`` pushes to an earlier `onIdToken` callback afterwards are ignored.
  public func logout() async {
    do {
      try await authProvider.logout()
      authBridge.endSession()
      try await ffiClient.setAuthCallback(provider: nil)
      authPublisher.send(AuthState.unauthenticated)
    } catch {
      dump(error)
    }
  }

  private func login(strategy: LoginStrategy) async -> Result<T, Error> {
    authPublisher.send(AuthState.loading)
    let session = authBridge.currentSession
    do {
      let authData = try await strategy(onIdTokenHandler(session: session))
      let token = authProvider.extractIdToken(from: authData)
      guard authBridge.activate(token: token, session: session) else {
        return Result.failure(CancellationError())
      }
      try await ffiClient.setAuthCallback(provider: authBridge)
      authPublisher.send(AuthState.authenticated(authData))
      return Result.success(authData)
    } catch {
      dump(error)
      authPublisher.send(AuthState.unauthenticated)
      return Result.failure(error)
    }
  }

  /// Lets the bridge refresh tokens through the ``AuthProvider`` when the Rust client asks for a
  /// fresh one (on reconnect, or after the backend rejected a token).
  ///
  /// `self` MUST be captured weakly: the Rust client keeps the bridge alive, so a strong capture
  /// would form a retain cycle across the FFI boundary (Rust client -> bridge -> refresh ->
  /// client -> `ffiClient` proxy -> Rust client) that keeps a discarded client's Rust core (its
  /// tokio runtime and its websocket) alive until process exit (get-convex/convex-swift#25).
  private func installRefresh() {
    authBridge.setRefresh { [weak self] session in
      guard let self else { return nil }
      let refreshData = try await self.authProvider.loginFromCache(
        onIdToken: self.onIdTokenHandler(session: session))
      return self.authProvider.extractIdToken(from: refreshData)
    }
  }

  /// Creates a sendable handler for token updates from the auth provider.
  ///
  /// This handler is passed to the auth provider during login and should be called
  /// whenever a fresh token is available or when the session becomes invalid. It only affects
  /// the session it was created for, and it captures `self` weakly for the same reason as
  /// ``installRefresh()``.
  private func onIdTokenHandler(session: UInt64) -> @Sendable (String?) -> Void {
    { [weak self] token in
      Task { await self?.receive(token: token, session: session) }
    }
  }

  private func receive(token: String?, session: UInt64) async {
    do {
      if let token {
        guard authBridge.update(token: token, session: session) else { return }
        // Re-installing the provider makes the Rust client pull the new token right away.
        // The bridge is the same object every time, so this never releases one in use.
        try await ffiClient.setAuthCallback(provider: authBridge)
      } else {
        guard authBridge.endSession(session) else { return }
        try await ffiClient.setAuthCallback(provider: nil)
        authPublisher.send(AuthState.unauthenticated)
      }
    } catch {
      dump(error)
      authPublisher.send(AuthState.unauthenticated)
    }
  }

  private typealias LoginStrategy = (@Sendable @escaping (String?) -> Void) async throws -> T
}

// Combine subjects are thread-safe, and the Rust client calls subscribers from its own threads.
private final class SubscriptionAdapter<T: Decodable>: QuerySubscriber, @unchecked Sendable {
  typealias Publisher = PassthroughSubject<T, ClientError>

  let publisher: Publisher

  init(publisher: Publisher) {
    self.publisher = publisher
  }

  func onError(message: String, value: String?) {
    let err: ClientError
    if let value {
      err = ClientError.ConvexError(data: value)
    } else {
      err = ClientError.ServerError(msg: message)
    }
    publisher.send(
      completion: Subscribers.Completion.failure(err))
  }

  func onUpdate(value: String) {
    do {
      publisher.send(try JSONDecoder().decode(Publisher.Output.self, from: Data(value.utf8)))
    } catch {
      publisher.send(
        completion: .failure(ClientError.InternalError(msg: error.localizedDescription)))
    }
  }
}

private final class WebSocketStateAdapter: WebSocketStateSubscriber, @unchecked Sendable {
  private let subject = PassthroughSubject<WebSocketState, Never>()
  
  init() { }

  func onStateChange(state: UniFFI.WebSocketState) {
    subject.send(state)
  }
  
  func newPublisher() -> AnyPublisher<WebSocketState, Never> {
    return subject.eraseToAnyPublisher()
  }
}
