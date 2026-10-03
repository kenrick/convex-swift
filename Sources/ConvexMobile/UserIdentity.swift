/// A user identity for an admin-authenticated client to act as; see
/// ``ConvexClient/setAdminAuth(adminKey:identity:)``.
///
/// Mirrors `UserIdentityAttributes` in the JavaScript and Rust clients, and encodes to the JSON
/// shape the Convex sync protocol uses. Either ``tokenIdentifier`` or both ``issuer`` and
/// ``subject`` must be set; when ``tokenIdentifier`` is `nil` the backend derives it as
/// `"<issuer>|<subject>"`.
public struct UserIdentity: Codable, Hashable, Sendable {
  public var tokenIdentifier: String?
  public var issuer: String?
  public var subject: String?
  public var name: String?
  public var givenName: String?
  public var familyName: String?
  public var nickname: String?
  public var preferredUsername: String?
  public var profileUrl: String?
  public var pictureUrl: String?
  public var websiteUrl: String?
  public var email: String?
  public var emailVerified: Bool?
  public var gender: String?
  public var birthday: String?
  public var timezone: String?
  public var language: String?
  public var phoneNumber: String?
  public var phoneNumberVerified: Bool?
  public var address: String?
  /// An RFC 3339 timestamp.
  public var updatedAt: String?

  public init(
    tokenIdentifier: String? = nil,
    issuer: String? = nil,
    subject: String? = nil,
    name: String? = nil,
    givenName: String? = nil,
    familyName: String? = nil,
    nickname: String? = nil,
    preferredUsername: String? = nil,
    profileUrl: String? = nil,
    pictureUrl: String? = nil,
    websiteUrl: String? = nil,
    email: String? = nil,
    emailVerified: Bool? = nil,
    gender: String? = nil,
    birthday: String? = nil,
    timezone: String? = nil,
    language: String? = nil,
    phoneNumber: String? = nil,
    phoneNumberVerified: Bool? = nil,
    address: String? = nil,
    updatedAt: String? = nil
  ) {
    self.tokenIdentifier = tokenIdentifier
    self.issuer = issuer
    self.subject = subject
    self.name = name
    self.givenName = givenName
    self.familyName = familyName
    self.nickname = nickname
    self.preferredUsername = preferredUsername
    self.profileUrl = profileUrl
    self.pictureUrl = pictureUrl
    self.websiteUrl = websiteUrl
    self.email = email
    self.emailVerified = emailVerified
    self.gender = gender
    self.birthday = birthday
    self.timezone = timezone
    self.language = language
    self.phoneNumber = phoneNumber
    self.phoneNumberVerified = phoneNumberVerified
    self.address = address
    self.updatedAt = updatedAt
  }
}
