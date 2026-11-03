import CommonCrypto
import CryptoKit
import Foundation

public enum AccountError: LocalizedError, Sendable {
  case invalidPassword, invalidData, notConfigured, insecureServer
  case response(Int, String), conflict, signedOut, busy
  public var errorDescription: String? {
    switch self {
    case .invalidPassword: "Use a password with at least 15 characters and at most 1,024 UTF-8 bytes."
    case .invalidData: "The encrypted library could not be verified. Your local changes have been kept."
    case .notConfigured: "The account service is not configured in this build."
    case .insecureServer: "The account service must use a secure HTTPS connection."
    case .response(_, let message): message
    case .conflict: "The library changed on another device. Sync and review changes before trying again."
    case .signedOut: "Sign in again to unlock your library. Unsynced changes have been kept."
    case .busy: "Wait for the current account operation to finish."
    }
  }
}

public struct AccountKeys: Sendable {
  public let salt: Data
  public let loginSecret: Data
  public let dataKey: Data
}

public enum AccountCrypto {
  public static let iterations = 600_000
  public static let maximumPlaintext = 1024 * 1024
  private static let aad = Data("pocahontas/snapshot/v1\n".utf8)

  public static func validatePassword(_ password: String) throws {
    let normalized = password.precomposedStringWithCanonicalMapping
    guard normalized.unicodeScalars.count >= 15, normalized.utf8.count <= 1024 else {
      throw AccountError.invalidPassword
    }
  }

  public static func randomSalt() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw AccountError.invalidData
    }
    return Data(bytes)
  }

  public static func derive(password: String, salt: Data) throws -> AccountKeys {
    guard salt.count == 32 else { throw AccountError.invalidData }
    let password = Data(password.precomposedStringWithCanonicalMapping.utf8)
    guard !password.isEmpty, password.count <= 1024 else { throw AccountError.invalidPassword }
    var master = Data(count: 32)
    defer { master.resetBytes(in: master.startIndex..<master.endIndex) }
    let status = master.withUnsafeMutableBytes { output in
      password.withUnsafeBytes { passwordBytes in
        salt.withUnsafeBytes { saltBytes in
          CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
            saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
            output.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
        }
      }
    }
    guard status == kCCSuccess else { throw AccountError.invalidData }
    func expand(_ purpose: String) -> Data {
      HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: master), salt: salt,
        info: Data("pocahontas/\(purpose)/v1".utf8), outputByteCount: 32)
        .withUnsafeBytes { Data($0) }
    }
    return AccountKeys(salt: salt, loginSecret: expand("login"), dataKey: expand("data"))
  }

  public static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
    guard plaintext.count <= maximumPlaintext, key.count == 32 else { throw AccountError.invalidData }
    let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad)
    guard let combined = box.combined,
      try decrypt(combined, key: key) == plaintext else { throw AccountError.invalidData }
    return combined
  }

  public static func decrypt(_ ciphertext: Data, key: Data) throws -> Data {
    guard (29...(maximumPlaintext + 28)).contains(ciphertext.count), key.count == 32 else {
      throw AccountError.invalidData
    }
    do {
      return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext),
        using: SymmetricKey(data: key), authenticating: aad)
    } catch { throw AccountError.invalidData }
  }
}

extension Data {
  public var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  public init(base64URL: String) throws {
    guard !base64URL.isEmpty, base64URL.utf8.allSatisfy({
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
    }) else { throw AccountError.invalidData }
    let string = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    guard let bytes = Data(base64Encoded: string + String(repeating: "=", count: (4 - string.count % 4) % 4)),
      bytes.base64URL == base64URL else { throw AccountError.invalidData }
    self = bytes
  }
}
