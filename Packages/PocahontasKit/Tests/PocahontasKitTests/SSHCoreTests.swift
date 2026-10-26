import Foundation
import XCTest

@testable import PocahontasKit

final class SSHCoreTests: XCTestCase {
  func testEncryptedAndPlainEd25519MatchOpenSSHPublicKeys() throws {
    for (name, passphrase) in [("ed25519_encrypted", "test-passphrase"), ("ed25519_plain", "")] {
      let privateKey = try fixture(name)
      let expected = try fixture(name + ".pub").split(separator: " ").prefix(2).joined(
        separator: " ")
      let credentials = try SSHCredentials(
        authentication: .ed25519(openSSH: privateKey, passphrase: passphrase))
      XCTAssertEqual(credentials.publicKey, expected)
      XCTAssertTrue(try SSHFingerprint.sha256(publicKey: expected).hasPrefix("SHA256:"))
    }
  }

  func testWrongPassphraseAndTruncatedKeysFailWithoutFallback() throws {
    let key = try fixture("ed25519_encrypted")
    for passphrase in ["", "wrong"] {
      XCTAssertThrowsError(
        try SSHCredentials(authentication: .ed25519(openSSH: key, passphrase: passphrase)))
    }
    XCTAssertThrowsError(
      try SSHCredentials(authentication: .ed25519(openSSH: String(key.prefix(80)), passphrase: "")))
  }

  func testTrustDecisionSeparatesFirstUseFromChangedKey() throws {
    let first = try fixture("ed25519_plain.pub").split(separator: " ").prefix(2).joined(
      separator: " ")
    let second = try fixture("ed25519_encrypted.pub").split(separator: " ").prefix(2).joined(
      separator: " ")
    XCTAssertEqual(try HostKeyDecision.evaluate(known: first, presented: first), .trusted)
    guard case .firstUse = try HostKeyDecision.evaluate(known: nil, presented: first) else {
      return XCTFail("New servers require a trust decision")
    }
    guard
      case .changed(let previous, let presented) = try HostKeyDecision.evaluate(
        known: first, presented: second)
    else {
      return XCTFail("Changed server keys must be blocked")
    }
    XCTAssertNotEqual(previous, presented)
  }

  func testConnectionValidationAndHostIdentity() throws {
    XCTAssertThrowsError(try SSHConnection(host: "", port: 22, username: "dev"))
    XCTAssertThrowsError(try SSHConnection(host: "example.com", port: 65536, username: "dev"))
    let first = try SSHConnection(host: "[::1]", port: 22, username: "dev")
    let second = try SSHConnection(host: "::1", port: 22, username: "root")
    XCTAssertEqual(first.hostIdentity, second.hostIdentity)
    XCTAssertEqual(first.host, "::1")
  }
}

func fixture(_ name: String) throws -> String {
  let url = try XCTUnwrap(
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}
