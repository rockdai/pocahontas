import Foundation
import Security

public protocol CredentialVault: Sendable {
  func read(_ reference: CredentialReference) throws -> String
  func insert(_ value: String, reference: CredentialReference) throws
  func delete(_ reference: CredentialReference) throws
}

public struct KeychainCredentialVault: CredentialVault {
  public let accessGroup: String?
  public init(accessGroup: String?) { self.accessGroup = accessGroup }
  private func query(_ reference: CredentialReference) throws -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.rockdai.pocahontas.credentials.local",
      kSecAttrAccount as String: reference.account,
      kSecAttrSynchronizable as String: false,
    ]
    #if os(macOS)
      query[kSecUseDataProtectionKeychain as String] = false
    #else
      query[kSecUseDataProtectionKeychain as String] = true
    #endif
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    return query
  }
  private func check(_ status: OSStatus) throws {
    switch status {
    case errSecSuccess: return
    case errSecItemNotFound: throw LibraryError.missingCredential
    case errSecInteractionNotAllowed: throw LibraryError.locked
    default: throw LibraryError.unavailableKeychain(status)
    }
  }
  public func read(_ reference: CredentialReference) throws -> String {
    var query = try query(reference)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    try check(SecItemCopyMatching(query as CFDictionary, &result))
    guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
      throw LibraryError.unavailableKeychain(errSecDecode)
    }
    return value
  }
  public func insert(_ value: String, reference: CredentialReference) throws {
    var query = try query(reference)
    query[kSecValueData as String] = Data(value.utf8)
    #if !os(macOS)
      query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    #endif
    // Revision addresses are immutable. Never update an existing item in place.
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecDuplicateItem, try read(reference) == value { return }
    try check(status)
    guard try read(reference) == value else { throw LibraryError.unavailableKeychain(errSecDecode) }
  }
  public func delete(_ reference: CredentialReference) throws {
    let status = SecItemDelete(try query(reference) as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }
}
