import CryptoKit
import Foundation
import Testing
@testable import PocahontasKit

@Suite("Account cryptography") struct AccountCryptoTests {
  @Test func matchesNodePBKDFAndHKDFAndDecryptsNodeCiphertext() throws {
    let keys = try AccountCrypto.derive(password: "Pocahontas test password 2026", salt: Data(0..<32))
    #expect(keys.loginSecret.map { String(format: "%02x", $0) }.joined() == "2bc66a6344447192b0a0cd48ec31a08a0db7d0c535969f555aae9671a9496884")
    #expect(keys.dataKey.map { String(format: "%02x", $0) }.joined() == "944f4ff2b889be912e6d9ba5ab55096db97728ebe312b5b9ea813005f440c4be")
    let cipher = try Data(base64URL: "AAECAwQFBgcICQoLIPzFGtAEeAj-lPhstjpdoIxATbRB-HKQdk1-BF_8t3Fa48a2B5j9HKjPZ5WENW-i")
    let plain = try AccountCrypto.decrypt(cipher, key: keys.dataKey)
    #expect(String(decoding: plain, as: UTF8.self) == "{\"schemaVersion\":1,\"records\":[]}")
    #expect(throws: AccountError.self) { try AccountCrypto.decrypt(cipher, key: keys.loginSecret) }
    var tampered = cipher
    tampered[tampered.count - 1] ^= 1
    #expect(throws: AccountError.self) { try AccountCrypto.decrypt(tampered, key: keys.dataKey) }
    let large = Data(repeating: 42, count: AccountCrypto.maximumPlaintext)
    let encoded = try AccountCrypto.encrypt(large, key: keys.dataKey)
    #expect(encoded.count == large.count + 28)
    #expect(try AccountCrypto.decrypt(encoded, key: keys.dataKey) == large)
  }
  @Test func normalizedPasswordsAndCanonicalEncoding() throws {
    let first = try AccountCrypto.derive(password: "Test password e\u{301} 2026", salt: Data(0..<32))
    let second = try AccountCrypto.derive(password: "Test password é 2026", salt: Data(0..<32))
    #expect(first.dataKey == second.dataKey)
    #expect(throws: AccountError.self) { try AccountCrypto.validatePassword("short") }
    #expect(throws: AccountError.self) { try Data(base64URL: "YQ==") }
    #expect(throws: AccountError.self) { try Data(base64URL: "YR") }
    #expect(throws: AccountError.self) { try AccountAPI(baseURL: URL(string: "http://example.com")!) }
    #expect(throws: LibraryError.self) {
      try VaultSnapshot.decode(Data("{\"schemaVersion\":2,\"records\":[]}".utf8), scope: "local")
    }
  }
  @Test func passwordLengthBoundaries() throws {
    #expect(throws: AccountError.self) { try AccountCrypto.validatePassword(String(repeating: "a", count: 14)) }
    try AccountCrypto.validatePassword(String(repeating: "a", count: 15))
    try AccountCrypto.validatePassword(String(repeating: "a", count: 1024))
    #expect(throws: AccountError.self) { try AccountCrypto.validatePassword(String(repeating: "a", count: 1025)) }
    try AccountCrypto.validatePassword(String(repeating: "é", count: 512))
    #expect(throws: AccountError.self) { try AccountCrypto.validatePassword(String(repeating: "é", count: 513)) }
    #expect(throws: AccountError.self) { try AccountCrypto.validatePassword(String(repeating: "e\u{301}", count: 14)) }
    try AccountCrypto.validatePassword(String(repeating: "e\u{301}", count: 15))
  }
  @Test func duplicateMetadataIDsCannotOverwriteDifferentRecordKinds() throws {
    let id = UUID()
    let data = try VaultSnapshot(records: [LibraryRecord(tombstone: id, kind: .host),
      LibraryRecord(tombstone: id, kind: .identity)]).encoded()
    #expect(throws: AccountError.self) { try VaultSnapshot.decode(data, scope: "local") }
  }
}

@Suite("Account server integration", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["POCAHONTAS_ACCOUNT_TEST_URL"] != nil))
@MainActor struct AccountIntegrationTests {
  private var baseURL: URL { URL(string: ProcessInfo.processInfo.environment["POCAHONTAS_ACCOUNT_TEST_URL"]!)! }
  private func code(email: String) async throws -> String {
    var url = URLComponents(url: baseURL.appendingPathComponent("test/code"), resolvingAgainstBaseURL: false)!
    url.queryItems = [URLQueryItem(name: "email", value: email)]
    let (data, _) = try await URLSession.shared.data(from: url.url!)
    return try #require((JSONSerialization.jsonObject(with: data) as? [String: String])?["code"])
  }
  private func library() throws -> (ConnectionLibrary, MemorySessionStore) {
    let session = MemorySessionStore()
    return (try ConnectionLibrary(store: LibraryStore(inMemory: true), vault: AccountTestVault(),
      api: AccountAPI(baseURL: baseURL), sessionStore: session), session)
  }
  private func loseNextWriteResponse() async throws {
    var request = URLRequest(url: baseURL.appendingPathComponent("test/fail-next-write"))
    request.httpMethod = "POST"
    _ = try await URLSession.shared.data(for: request)
  }
  @Test func twoDevicesShareCredentialsMergeEditsAndHandlePasswordChangesAndReset() async throws {
    let email = "swift-\(UUID().uuidString.lowercased())@example.test"
    let password = "Pocahontas test password 2026"
    let newPassword = "Pocahontas changed password 2026"
    let (a, sessionA) = try library()
    let (b, _) = try library()
    let codeId = try await a.requestCode(email: email, reset: false)
    try await a.registerOrReset(email: email, password: password, codeId: codeId,
      code: code(email: email), reset: false)
    try await b.signIn(email: email, password: password)
    #expect(a.scope == b.scope)
    let reference = try a.savePassword("shared SSH test password", storage: .account)
    let host = LibraryRecord(name: "Agent box", binding: try ConnectionBinding(host: "dev.example.test", port: 22,
      username: "developer", authentication: .password(reference)))
    try a.save(host)
    try await loseNextWriteResponse()
    await a.syncNow()
    #expect(a.state.pendingUpload != nil)
    let committed = try await AccountAPI(baseURL: baseURL).vault(token: #require(sessionA.value?.token))
    a.errorMessage = nil
    await a.syncNow()
    #expect(a.errorMessage == nil)
    #expect(a.state.pendingUpload == nil)
    #expect(a.state.remoteUpdatedAt == committed.updatedAt)
    await b.syncNow()
    #expect(b.hosts.count == 1)
    let (_, authentication) = try await b.authentication(for: host.id)
    if case .password(let value) = authentication { #expect(value == "shared SSH test password") }
    else { Issue.record("Shared credential did not arrive") }

    b.syncEnabled = false
    b.queuedSync?.cancel()
    var local = try #require(b.state.records[host.id]?.record)
    local.tags = ["offline"]
    try b.save(local)
    var remote = try #require(a.state.records[host.id]?.record)
    remote.name = "Renamed on Mac"
    try a.save(remote)
    await a.syncNow()
    b.syncEnabled = true
    await b.syncNow()
    await a.syncNow()
    #expect(a.state.records[host.id]?.record?.tags == ["offline"])
    #expect(b.state.records[host.id]?.record?.name == "Renamed on Mac")
    #expect(b.conflictCount == 0)

    b.syncEnabled = false
    b.queuedSync?.cancel()
    local = try #require(b.state.records[host.id]?.record)
    local.name = "Unsent before password change"
    try b.save(local)
    // The password change committed, but its reply was lost. New-password login confirms success.
    try await loseNextWriteResponse()
    try await a.changePassword(oldPassword: password, newPassword: newPassword)
    #expect(a.hosts.count == 1)
    b.syncEnabled = true
    await b.syncNow()
    #expect(!b.isSignedIn)
    #expect(b.state.records[host.id]?.record?.name == "Unsent before password change")
    try await b.signIn(email: email, password: newPassword)
    #expect(b.hosts.first?.record?.name == "Renamed on Mac")
    #expect(try b.archivedRecords().contains { $0.name == "Unsent before password change" })
    await b.syncNow()
    #expect(b.pendingCount == 0)

    b.syncEnabled = false
    b.queuedSync?.cancel()
    local = try #require(b.state.records[host.id]?.record)
    local.name = "Unsent before reset"
    try b.save(local)
    let (reset, _) = try library()
    let resetID = try await reset.requestCode(email: email, reset: true)
    try await loseNextWriteResponse()
    try await reset.registerOrReset(email: email, password: password, codeId: resetID,
      code: code(email: email), reset: true, confirmDelete: true)
    b.syncEnabled = true
    await b.syncNow()
    try await b.signIn(email: email, password: password)
    #expect(b.hosts.isEmpty)
    #expect(try b.archivedRecords().contains { $0.name == "Unsent before reset" })
    #expect(try b.archivedRecords().contains { $0.name == "Unsent before password change" })
    await b.syncNow()
    #expect(reset.hosts.isEmpty)
    try b.copyArchivedChangesToLocal()
    #expect(try b.store.read(scope: "local").records.values.contains { $0.record?.name == "Unsent before reset" })
    #expect(try b.store.read(scope: "local").records.values.contains { $0.record?.name == "Unsent before password change" })
    try a.signOut()
    #expect(sessionA.value == nil)
    #expect(a.scope == "local")
  }
}

private final class MemorySessionStore: AccountSessionStore, @unchecked Sendable {
  var value: AccountSession?
  func read() -> AccountSession? { value }
  func save(_ value: AccountSession) { self.value = value }
  func clear() { value = nil }
}
private final class AccountTestVault: CredentialVault, @unchecked Sendable {
  var items: [String: String] = [:]
  func read(_ reference: CredentialReference) throws -> String {
    guard let value = items[reference.account] else { throw LibraryError.missingCredential }
    return value
  }
  func insert(_ value: String, reference: CredentialReference) throws {
    if let old = items[reference.account], old != value { throw AccountError.invalidData }
    items[reference.account] = value
  }
  func delete(_ reference: CredentialReference) { items[reference.account] = nil }
}
