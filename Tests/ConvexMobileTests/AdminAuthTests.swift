import Foundation
import XCTest

@testable import ConvexMobile
@testable import UniFFI

final class AdminAuthTests: XCTestCase {

  func testSetAdminAuthSendsKeyAndIdentityJSON() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexClient(ffiClient: fakeFfiClient)

    try await client.setAdminAuth(
      adminKey: "admin-key",
      identity: UserIdentity(
        tokenIdentifier: "harby-local-dev|local-dev:dev@example.com",
        issuer: "harby-local-dev",
        subject: "local-dev:dev@example.com",
        name: "Dev",
        email: "dev@example.com",
        emailVerified: true))

    let adminAuth = try XCTUnwrap(fakeFfiClient.adminAuth)
    XCTAssertEqual(adminAuth.adminKey, "admin-key")
    let json = try XCTUnwrap(adminAuth.actingAsJson)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      ["tokenIdentifier", "issuer", "subject", "name", "email", "emailVerified"],
      "identity must use the protocol's camelCase keys and omit unset fields")
    XCTAssertEqual(object["subject"] as? String, "local-dev:dev@example.com")
    XCTAssertEqual(object["emailVerified"] as? Bool, true)
  }

  func testSetAdminAuthWithoutIdentity() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexClient(ffiClient: fakeFfiClient)

    try await client.setAdminAuth(adminKey: "admin-key")

    XCTAssertEqual(fakeFfiClient.adminAuth?.adminKey, "admin-key")
    XCTAssertNil(fakeFfiClient.adminAuth?.actingAsJson)
  }

  func testIdentityDecodesFromDevTokenResponse() throws {
    let identity = try JSONDecoder().decode(
      UserIdentity.self,
      from: Data(
        """
        {"subject":"local-dev:dev@example.com","issuer":"harby-local-dev",
         "tokenIdentifier":"harby-local-dev|local-dev:dev@example.com",
         "email":"dev@example.com","name":"Dev","emailVerified":true}
        """.utf8))
    XCTAssertEqual(
      identity,
      UserIdentity(
        tokenIdentifier: "harby-local-dev|local-dev:dev@example.com",
        issuer: "harby-local-dev",
        subject: "local-dev:dev@example.com",
        name: "Dev",
        email: "dev@example.com",
        emailVerified: true))
  }

  func testAdminAuthEndsTheProviderSession() async throws {
    let core = ThreadSafeFakeMobileConvexClient()
    let provider = ThreadSafeFakeAuthProvider()
    let client = ConvexClientWithAuth(ffiClient: core, authProvider: provider)
    _ = try await client.login().get()

    try await client.setAdminAuth(adminKey: "admin-key", identity: UserIdentity(tokenIdentifier: "t"))
    XCTAssertNil(core.installedProvider)

    // A refresh from the earlier session must not replace the admin auth.
    provider.pushToken("late-token")
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertNil(core.installedProvider)
  }
}
