import Foundation
import Testing

@testable import PocahontasKit

private func host(_ name: String = "Agent box") throws -> LibraryRecord {
  LibraryRecord(
    name: name,
    binding: try ConnectionBinding(
      host: "dev.example.test", port: 22,
      username: "developer", authentication: .password(nil)))
}
private func baseline(_ value: LibraryRecord) throws -> StoredRecord {
  var row = try StoredRecord(value)
  try row.acknowledge(value.encoded())
  return row
}

@Suite("Connection library") struct LibraryTests {
  @Test func disjointEditsMergeWithoutDiscardingEitherSide() throws {
    let base = try host()
    var row = try baseline(base)
    var local = base
    local.name = "Mac edit"
    local.revision = UUID()
    row.payload = try local.encoded()
    row.dirty = true
    var remote = base
    remote.tags = ["remote edit"]
    remote.revision = UUID()
    try row.receive(remote.encoded())
    #expect(row.record?.name == "Mac edit")
    #expect(row.record?.tags == ["remote edit"])
    #expect(row.conflict == nil)
    #expect(row.dirty)
  }
  @Test func endpointAndAuthenticationCannotBeCombinedAcrossDevices() throws {
    let base = try host()
    var row = try baseline(base)
    var local = base
    local.binding?.host = "other.example.test"
    local.revision = UUID()
    row.payload = try local.encoded()
    row.dirty = true
    var remote = base
    remote.binding?.authentication = .identity(UUID())
    remote.tags = ["keep me"]
    remote.revision = UUID()
    try row.receive(remote.encoded())
    #expect(row.conflict?.fields == ["connection"])
    #expect(row.record?.binding == local.binding)
    // Repeated delivery doesn't clear an unresolved conflict.
    try row.receive(remote.encoded())
    #expect(row.conflict?.fields == ["connection"])
    try row.resolve(useRemote: true)
    #expect(row.record?.binding == remote.binding)
    #expect(row.record?.tags == ["keep me"])
    #expect(row.conflict == nil)
  }
  @Test func deletionWinsAgainstOfflineChangesInEitherDirection() throws {
    let base = try host()
    var edited = base
    edited.name = "offline"
    edited.revision = UUID()
    var deleted = base
    deleted.deleted = true
    deleted.revision = UUID()
    var localEdit = try baseline(base)
    localEdit.payload = try edited.encoded()
    localEdit.dirty = true
    try localEdit.receive(deleted.encoded())
    #expect(localEdit.record?.deleted == true)
    #expect(!localEdit.dirty)
    var localDelete = try baseline(base)
    localDelete.payload = try deleted.encoded()
    localDelete.dirty = true
    try localDelete.receive(edited.encoded())
    #expect(localDelete.record?.deleted == true)
    #expect(localDelete.dirty)
  }
  @Test func ackDoesNotClearNewerUnsentRevision() throws {
    let first = try host()
    var row = try StoredRecord(first)
    var newer = first
    newer.name = "Edited during upload"
    newer.revision = UUID()
    row.payload = try newer.encoded()
    try row.acknowledge(first.encoded())
    #expect(row.dirty)
    #expect(row.record == newer)
    #expect(try LibraryRecord.decode(row.base!) == first)
    try row.acknowledge(newer.encoded())
    #expect(!row.dirty)
  }
  @Test func futureSchemaIsKeptOpaqueAndCannotBeUploaded() throws {
    let first = try host()
    var row = try StoredRecord(first)
    var future = first
    future.schemaVersion = 99
    let bytes = try future.encoded()
    try row.receive(bytes)
    #expect(row.isReadOnly)
    #expect(row.payload == bytes)
    #expect(!row.dirty)
    #expect(row.conflict?.remote == first)
    #expect(throws: LibraryError.self) { try row.resolve(useRemote: false) }
  }
  @Test func snapshotHasExplicitTypesAndMinimalTombstones() throws {
    var value = try host()
    let data = try VaultSnapshot(records: [value]).encoded()
    let decoded = try VaultSnapshot.decode(data, scope: "local")
    #expect(decoded.records.first == value)
    #expect(decoded.credentials.isEmpty)
    #expect(String(decoding: data, as: UTF8.self).contains("\"type\":\"password\""))
    value.deleted = true
    let deleted = try VaultSnapshot(records: [value]).encoded()
    let json = try #require(JSONSerialization.jsonObject(with: deleted) as? [String: Any])
    let entries = try #require(json["records"] as? [[String: Any]])
    #expect(Set(entries[0].keys) == Set(["id", "type", "deleted"]))
  }
  @Test @MainActor func transactionSurvivesReopenAndScopesStaySeparate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.sqlite")
    let value = try host()
    do {
      let store = try LibraryStore(url: url)
      var state = LibraryState()
      state.records[value.id] = try StoredRecord(value)
      state.remoteUpdatedAt = "2026-11-04T00:00:00.000Z"
      try store.write(state, scope: "account-A")
    }
    let reopened = try LibraryStore(url: url)
    let saved = try reopened.read(scope: "account-A")
    #expect(saved.records[value.id]?.record == value)
    #expect(saved.records[value.id]?.dirty == true)
    #expect(saved.remoteUpdatedAt == "2026-11-04T00:00:00.000Z")
    #expect(try reopened.read(scope: "account-B").records.isEmpty)
    #expect(try reopened.read(scope: "local").records.isEmpty)
  }
  @Test @MainActor func failedSecretWriteNeverPublishesReference() throws {
    let vault = TestVault()
    vault.failure = .locked
    let library = try makeLibrary(vault)
    #expect(throws: LibraryError.self) {
      try library.savePassword("do-not-persist", storage: .device)
    }
    #expect(library.hosts.isEmpty)
    #expect(library.pendingCount == 0)
  }
  @Test @MainActor func missingCredentialDoesNotFallbackOrRemoveBinding() async throws {
    let library = try makeLibrary(TestVault())
    var value = try host()
    let ref = CredentialReference(ownerScope: "local", kind: .password, storage: .account)
    value.binding?.authentication = .password(ref)
    try library.save(value)
    await #expect(throws: LibraryError.self) { try await library.authentication(for: value.id) }
    #expect(library.state.records[value.id]?.record?.binding?.authentication == .password(ref))
    let (_, auth) = try await library.authentication(
      for: value.id, oneTimePassword: "one connection")
    if case .password(let password) = auth {
      #expect(password == "one connection")
    } else {
      Issue.record("Unexpected fallback")
    }
  }
  @Test @MainActor func scopeSwitchQuarantinesOldOutboxAndOverridesStayLocal() throws {
    let vault = TestVault()
    let library = try makeLibrary(vault)
    let value = try host()
    try library.save(value)
    let ref = try library.savePassword("local-password", storage: .device)
    try library.setLocalAuthentication(.password(ref), for: value.id)
    #expect(library.state.records[value.id]?.record?.binding?.authentication == .password(nil))
    try library.switchScope("account-A")
    #expect(library.hosts.isEmpty)
    #expect(library.pendingCount == 0)
    #expect(library.state.localOverrides.isEmpty)
    try library.switchScope("local")
    #expect(library.hosts.count == 1)
    #expect(library.pendingCount == 1)
    #expect(library.state.localOverrides[value.id] == .password(ref))
    #expect(vault.references.allSatisfy { $0.storage == .device })
    let data = try JSONEncoder().encode(library.state)
    #expect(!String(decoding: data, as: UTF8.self).contains("local-password"))
  }
  @Test @MainActor func tombstoneCannotBeEditedBackToLife() throws {
    let library = try makeLibrary(TestVault())
    let value = try host()
    try library.save(value)
    try library.delete(value.id)
    #expect(library.hosts.isEmpty)
    #expect(throws: LibraryError.self) { try library.save(value) }
    #expect(library.state.records[value.id]?.record?.deleted == true)
  }
  @Test @MainActor func staleEditorCannotSilentlyOverwriteANewerRevision() throws {
    let library = try makeLibrary(TestVault())
    let value = try host()
    try library.save(value)
    var stale = try #require(library.state.records[value.id]?.record)
    var newer = stale
    newer.tags = ["another window"]
    try library.save(newer)
    stale.name = "old editor"
    #expect(throws: LibraryError.self) { try library.save(stale) }
    #expect(library.state.records[value.id]?.record?.tags == ["another window"])
  }
  @Test @MainActor func accountInvalidationImmediatelyHidesCredentialsAndKeepsOldOutbox()
    async throws
  {
    let vault = TestVault()
    let library = try makeLibrary(vault)
    try library.switchScope("account-A")
    library.accountScope = "account-A"
    let reference = try library.savePassword("account-A-secret", storage: .device)
    var value = try host()
    value.binding?.authentication = .password(reference)
    try library.save(value)
    let generation = library.accountGeneration
    try library.signOut()
    #expect(library.accountGeneration > generation)
    #expect(library.accountScope == nil)
    #expect(library.scope == "local")
    #expect(library.hosts.isEmpty)
    await #expect(throws: LibraryError.self) { try await library.authentication(for: value.id) }
    #expect(try library.store.read(scope: "account-A").records[value.id]?.dirty == true)
    #expect(try vault.read(reference) == "account-A-secret")
  }
  @Test @MainActor func failedStorageCannotBeReplacedByAnEmptySnapshot() throws {
    let library = try makeLibrary(TestVault())
    let original = try host()
    try library.save(original)
    // Simulate an account invalidation that couldn't read the local snapshot.
    library.state = LibraryState()
    library.storageFailed = true
    library.failPersistence(LibraryError.invalidRecord)
    #expect(throws: LibraryError.self) { try library.save(host("Do not overwrite")) }
    #expect(throws: LibraryError.self) {
      try library.savePassword("do not publish", storage: .device)
    }
    #expect(try library.store.read(scope: "local").records[original.id] != nil)
  }
  @MainActor private func makeLibrary(_ vault: TestVault) throws -> ConnectionLibrary {
    try ConnectionLibrary(
      store: LibraryStore(inMemory: true), vault: vault)
  }
}

private final class TestVault: CredentialVault, @unchecked Sendable {
  // Tests use this only from MainActor; the production vault is the Security framework.
  var items: [String: String] = [:]
  var references: [CredentialReference] = []
  var failure: LibraryError?
  func read(_ reference: CredentialReference) throws -> String {
    if let failure { throw failure }
    guard let value = items[reference.account] else { throw LibraryError.missingCredential }
    return value
  }
  func insert(_ value: String, reference: CredentialReference) throws {
    if let failure { throw failure }
    references.append(reference)
    items[reference.account] = value
  }
  func delete(_ reference: CredentialReference) throws { items[reference.account] = nil }
}
