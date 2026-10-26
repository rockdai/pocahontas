import Foundation
import Security

public protocol KnownHostsStore: Sendable {
  func key(for host: String) throws -> String?
  func trust(_ key: String, for host: String) throws
}

public struct KeychainKnownHosts: KnownHostsStore {
  private let service: String

  public init(service: String = "com.rockdai.pocahontas.known-hosts") { self.service = service }

  private func query(_ host: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: host,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  public func key(for host: String) throws -> String? {
    var attributes = query(host)
    attributes[kSecReturnData as String] = true
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(attributes as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    guard let bytes = result as? Data, let text = String(data: bytes, encoding: .utf8) else {
      throw KeychainError(status: errSecDecode)
    }
    return text
  }

  public func trust(_ key: String, for host: String) throws {
    var attributes = query(host)
    attributes[kSecValueData as String] = Data(key.utf8)
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecDuplicateItem, try self.key(for: host) == key { return }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }
}

public struct KeychainError: LocalizedError, Sendable {
  public let status: OSStatus
  public var errorDescription: String? { "Unable to access the device keychain (\(status))." }
}

public struct HostKeyChallenge: Sendable, Identifiable {
  public let id = UUID()
  public let host: String
  public let fingerprint: String
}

public enum HostKeyDecision: Equatable, Sendable {
  case trusted
  case firstUse(fingerprint: String)
  case changed(previous: String, presented: String)

  public static func evaluate(known: String?, presented: String) throws -> Self {
    let fingerprint = try SSHFingerprint.sha256(publicKey: presented)
    guard let known else { return .firstUse(fingerprint: fingerprint) }
    if known == presented { return .trusted }
    return .changed(previous: try SSHFingerprint.sha256(publicKey: known), presented: fingerprint)
  }
}
