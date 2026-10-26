import Citadel
import Crypto
import Foundation
import NIOSSH

// Immutable key material; authentication delegates only read it on their event loop.
public struct SSHCredentials: @unchecked Sendable {
  let offer: NIOSSHUserAuthenticationOffer.Offer
  public let publicKey: String?

  public init(authentication: SSHAuthentication) throws {
    switch authentication {
    case .password(let value):
      offer = .password(.init(password: value))
      publicKey = nil
    case .ed25519(let openSSH, let passphrase):
      let normalized = openSSH.replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard normalized.utf8.count <= 64 * 1024 else { throw SSHSessionError.invalidPrivateKey }
      do {
        guard try SSHKeyDetection.detectPrivateKeyType(from: normalized) == .ed25519 else {
          throw SSHSessionError.unsupportedPrivateKey
        }
        let key = try Curve25519.Signing.PrivateKey(
          sshEd25519: normalized,
          decryptionKey: passphrase.isEmpty ? nil : Data(passphrase.utf8)
        )
        let sshKey = NIOSSHPrivateKey(ed25519Key: key)
        offer = .privateKey(.init(privateKey: sshKey))
        publicKey = String(openSSHPublicKey: sshKey.publicKey)
      } catch let error as SSHSessionError {
        throw error
      } catch {
        throw SSHSessionError.invalidPrivateKey
      }
    }
  }
}

public enum SSHFingerprint {
  public static func sha256(publicKey: String) throws -> String {
    let fields = publicKey.split(whereSeparator: { $0.isWhitespace })
    guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
      throw SSHSessionError.invalidPrivateKey
    }
    return "SHA256:"
      + Data(SHA256.hash(data: blob)).base64EncodedString()
      .replacingOccurrences(of: "=", with: "")
  }
}
