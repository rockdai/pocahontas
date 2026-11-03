import Foundation
import Security

public struct AccountSession: Codable, Sendable {
  public var email: String
  public var userId: String
  public var token: String
  public var expiresAt: String
  public var passwordUpdatedAt: String
  public var salt: Data
  public var dataKey: Data
}

public protocol AccountSessionStore: Sendable {
  func read() throws -> AccountSession?
  func save(_ value: AccountSession) throws
  func clear() throws
}

public struct KeychainAccountSessionStore: AccountSessionStore {
  private let service: String
  public init(server: URL) { service = "com.rockdai.pocahontas.account." + server.absoluteString }
  private var query: [String: Any] {
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: "session",
      kSecAttrSynchronizable as String: false]
    #if os(macOS)
      query[kSecUseDataProtectionKeychain as String] = false
    #else
      query[kSecUseDataProtectionKeychain as String] = true
    #endif
    return query
  }
  public func read() throws -> AccountSession? {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw LibraryError.unavailableKeychain(status) }
    guard let data = result as? Data else { throw AccountError.invalidData }
    return try JSONDecoder().decode(AccountSession.self, from: data)
  }
  public func save(_ value: AccountSession) throws {
    let bytes = try JSONEncoder().encode(value)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw LibraryError.unavailableKeychain(status) }
    var query = query
    query[kSecValueData as String] = bytes
    #if !os(macOS)
      query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    #endif
    let added = SecItemAdd(query as CFDictionary, nil)
    guard added == errSecSuccess else { throw LibraryError.unavailableKeychain(added) }
  }
  public func clear() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw LibraryError.unavailableKeychain(status) }
  }
}
