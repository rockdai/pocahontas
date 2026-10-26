import Foundation
import XCTest

@testable import PocahontasKit

final class SSHIntegrationTests: XCTestCase, @unchecked Sendable {
  private func connection() throws -> SSHConnection {
    guard let value = ProcessInfo.processInfo.environment["POCAHONTAS_SSH_TEST_PORT"],
      let port = Int(value)
    else {
      throw XCTSkip("Run scripts/test-ssh.sh for loopback SSH integration tests.")
    }
    return try .init(host: "127.0.0.1", port: port, username: "fixture")
  }

  func testPasswordSessionTransmitsBinaryAndResize() async throws {
    try await exercise(.password("pocahontas-test"))
  }

  func testEncryptedEd25519AuthenticatesToServer() async throws {
    try await exercise(
      .ed25519(openSSH: fixture("ed25519_encrypted"), passphrase: "test-passphrase"))
  }

  private func exercise(_ authentication: SSHAuthentication) async throws {
    let connection = try connection()
    let ready = expectation(description: "PTY and shell accepted")
    let echoed = expectation(description: "binary output preserved")
    let resized = expectation(description: "remote PTY resized")
    let store = MemoryKnownHosts()
    let received = ReceivedBytes()
    let payload = Data([0xff, 0x00, 0xc3, 0xa9]) + Data("pocahontas-probe".utf8)
    let session = SSHSession(
      connection: connection, credentials: try SSHCredentials(authentication: authentication),
      knownHosts: store, onTrust: { _, completion in completion(true) },
      onOutput: { bytes, done in
        let aggregate = received.append(bytes)
        if aggregate.range(of: payload) != nil, received.mark("echo") { echoed.fulfill() }
        if aggregate.range(of: Data("RESIZE:91x37".utf8)) != nil, received.mark("resize") {
          resized.fulfill()
        }
        done()
      },
      onState: { state in
        if state == .ready { ready.fulfill() }
        if case .failed(let message) = state { XCTFail(message) }
      })
    defer { session.stop() }
    session.start()
    await fulfillment(of: [ready], timeout: 10)
    session.resize(.init(columns: 91, rows: 37))
    session.send(payload)
    await fulfillment(of: [echoed, resized], timeout: 10)
    XCTAssertNotNil(try store.key(for: connection.hostIdentity))
  }

  func testChangedHostKeyBlocksAuthentication() async throws {
    let connection = try connection()
    let failed = expectation(description: "changed host blocked")
    let store = MemoryKnownHosts()
    try store.trust(
      fixture("ed25519_plain.pub").split(separator: " ").prefix(2).joined(separator: " "),
      for: connection.hostIdentity)
    let session = SSHSession(
      connection: connection, credentials: try .init(authentication: .password("pocahontas-test")),
      knownHosts: store, onTrust: { _, _ in XCTFail("A changed host must not get a TOFU prompt") },
      onOutput: { _, done in done() },
      onState: { state in
        if state == .ready { XCTFail("Changed host must never become ready") }
        if case .failed(let message) = state {
          XCTAssertTrue(message.contains("identity changed"))
          failed.fulfill()
        }
      })
    defer { session.stop() }
    session.start()
    await fulfillment(of: [failed], timeout: 10)
  }

  func testRejectedHostIsNotRemembered() async throws {
    let connection = try connection()
    let ended = expectation(description: "trust rejected")
    let store = MemoryKnownHosts()
    let session = SSHSession(
      connection: connection, credentials: try .init(authentication: .password("pocahontas-test")),
      knownHosts: store, onTrust: { _, reply in reply(false) },
      onOutput: { _, done in done() },
      onState: { state in
        if state == .ready { XCTFail("Untrusted host must never become ready") }
        if case .failed = state { ended.fulfill() }
      })
    defer { session.stop() }
    session.start()
    await fulfillment(of: [ended], timeout: 10)
    XCTAssertNil(try store.key(for: connection.hostIdentity))
  }

  func testWrongPasswordFailsPromptly() async throws {
    let connection = try connection()
    let failed = expectation(description: "authentication rejected")
    let session = SSHSession(
      connection: connection, credentials: try .init(authentication: .password("wrong-password")),
      knownHosts: MemoryKnownHosts(), onTrust: { _, reply in reply(true) },
      onOutput: { _, done in done() },
      onState: { state in
        if state == .ready { XCTFail("Wrong password must never become ready") }
        if case .failed(let message) = state {
          XCTAssertTrue(message.contains("rejected"))
          failed.fulfill()
        }
      })
    defer { session.stop() }
    session.start()
    await fulfillment(of: [failed], timeout: 3)
  }
}

private final class MemoryKnownHosts: KnownHostsStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String: String] = [:]
  func key(for host: String) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return keys[host]
  }
  func trust(_ key: String, for host: String) throws {
    lock.lock()
    keys[host] = key
    lock.unlock()
  }
}

private final class ReceivedBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private var marks: Set<String> = []
  func append(_ bytes: Data) -> Data {
    lock.lock()
    defer { lock.unlock() }
    data.append(bytes)
    return data
  }
  func mark(_ name: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return marks.insert(name).inserted
  }
}
