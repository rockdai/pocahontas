import Foundation
import Observation

@MainActor @Observable public final class ConnectionLibrary {
  public internal(set) var state = LibraryState()
  public internal(set) var scope = "local"
  public internal(set) var accountScope: String?
  public internal(set) var accountEmail: String?
  public internal(set) var syncEnabled = false
  public internal(set) var syncStatus = "Saved on this device"
  public internal(set) var lastSync: Date?
  public internal(set) var accountGeneration = 0
  public internal(set) var isSyncing = false
  public internal(set) var isAccountBusy = false
  public var errorMessage: String?
  public let serverConfigured: Bool
  @ObservationIgnored let store: LibraryStore
  @ObservationIgnored let vault: any CredentialVault
  @ObservationIgnored let api: AccountAPI?
  @ObservationIgnored let sessionStore: (any AccountSessionStore)?
  @ObservationIgnored var session: AccountSession?
  @ObservationIgnored var syncTask: Task<Void, Never>?
  @ObservationIgnored var queuedSync: Task<Void, Never>?
  @ObservationIgnored var scopeEpoch = 0
  @ObservationIgnored var storageFailed = false
  @ObservationIgnored var restored = false

  public init(store: LibraryStore, vault: any CredentialVault, api: AccountAPI? = nil,
    sessionStore: (any AccountSessionStore)? = nil
  ) throws {
    self.store = store
    self.vault = vault
    self.api = api
    self.sessionStore = sessionStore
    serverConfigured = api != nil
    state = try store.read(scope: "local")
  }
  public var isSignedIn: Bool { session != nil }
  func ensureEditable() throws {
    guard !isAccountBusy else { throw AccountError.busy }
    guard !storageFailed else { throw LibraryError.recoveryRequired }
    guard state.blockedVault == nil else { throw LibraryError.newerSchema }
  }
  func rememberShared(_ reference: CredentialReference) throws {
    if reference.storage == .account {
      try transaction { $0.sharedCredentials[reference.revision] = reference }
      enqueueChanges()
    }
  }
  public var hosts: [StoredRecord] { visible(.host) }
  public var identities: [StoredRecord] { visible(.identity) }
  public var pendingCount: Int { state.records.values.filter(\.dirty).count }
  public var conflictCount: Int { state.records.values.filter { $0.conflict != nil }.count }
  public var unknownCount: Int { state.records.values.filter(\.isReadOnly).count + (state.blockedVault == nil ? 0 : 1) }
  private func visible(_ kind: LibraryRecord.Kind) -> [StoredRecord] {
    state.records.values.filter { $0.record?.kind == kind && $0.record?.deleted == false }
      .sorted {
        ($0.record?.name ?? "").localizedStandardCompare($1.record?.name ?? "") == .orderedAscending
      }
  }
  func transaction(_ mutate: (inout LibraryState) throws -> Void) throws {
    guard !storageFailed else { throw LibraryError.recoveryRequired }
    var next = state
    try mutate(&next)
    try store.write(next, scope: scope)
    state = next
  }
  public func save(_ record: LibraryRecord) throws {
    try save(record, localAuthentication: state.localOverrides[record.id])
  }
  public func save(_ record: LibraryRecord, localAuthentication: SavedAuthentication?) throws {
    try ensureEditable()
    guard record.schemaVersion == 1 else { throw LibraryError.newerSchema }
    if let reference = record.identity?.secret { try checkReference(reference) }
    if case .password(let reference) = record.binding?.authentication, let reference {
      try checkReference(reference)
    }
    if case .password(let reference) = localAuthentication, let reference {
      try checkReference(reference)
    }
    if let old = state.records[record.id] {
      guard !old.isReadOnly else { throw LibraryError.newerSchema }
      guard old.conflict == nil else { throw LibraryError.conflict }
      guard old.record?.deleted == false else { throw LibraryError.invalidRecord }
      guard old.record?.revision == record.revision else { throw LibraryError.conflict }
    }
    var value = record
    value.revision = UUID()
    try transaction {
      var row = try $0.records[value.id] ?? StoredRecord(value)
      row.payload = try value.encoded()
      row.dirty = true
      $0.records[value.id] = row
      $0.localOverrides[value.id] = localAuthentication
    }
    enqueueChanges()
  }
  public func delete(_ id: UUID) throws {
    try ensureEditable()
    guard var row = state.records[id], var record = row.record else {
      throw LibraryError.newerSchema
    }
    record.deleted = true
    record.revision = UUID()
    row.payload = try record.encoded()
    row.conflict = nil
    row.dirty = true
    try transaction {
      $0.records[id] = row
      $0.localOverrides[id] = nil
    }
    // Deliberately retain secrets and other identities: slower devices may still reference them.
    enqueueChanges()
  }
  public func resolve(_ id: UUID, useRemote: Bool) throws {
    try ensureEditable()
    try transaction { try $0.records[id]?.resolve(useRemote: useRemote) }
    enqueueChanges()
  }
  public func savePassword(_ password: String, storage: SecretStorage) throws -> CredentialReference
  {
    let reference = try newReference(kind: .password, storage: storage)
    try vault.insert(password, reference: reference)
    try rememberShared(reference)
    return reference
  }
  public func importIdentity(
    name: String, privateKey: String, passphrase: String,
    storage: SecretStorage, replacing id: UUID? = nil
  ) async throws {
    try ensureEditable()
    let epoch = scopeEpoch
    let original = id.flatMap { state.records[$0]?.record }
    let credentials = try await Task.detached {
      try SSHCredentials(authentication: .ed25519(openSSH: privateKey, passphrase: passphrase))
    }.value
    guard epoch == scopeEpoch else { throw LibraryError.accountChanged }
    guard let publicKey = credentials.publicKey else { throw LibraryError.invalidRecord }
    let reference = try newReference(kind: .privateKey, storage: storage)
    try vault.insert(privateKey, reference: reference)
    try rememberShared(reference)
    var record = LibraryRecord(
      name: name,
      identity: try IdentityMaterial(
        publicKey: publicKey, secret: reference, requiresPassphrase: !passphrase.isEmpty))
    if let id {
      guard let original else { throw LibraryError.identityMissing }
      record.id = id
      record.revision = original.revision
    }
    try save(record)
    // Passphrases are intentionally session-only in this release.
  }
  private func newReference(kind: SecretKind, storage: SecretStorage) throws -> CredentialReference
  {
    try ensureEditable()
    if storage == .account {
      guard serverConfigured, session != nil, let accountScope, scope == accountScope else {
        throw AccountError.notConfigured
      }
    }
    return CredentialReference(ownerScope: scope, kind: kind, storage: storage)
  }
  public func setLocalAuthentication(_ authentication: SavedAuthentication?, for id: UUID) throws {
    try ensureEditable()
    guard state.records[id]?.record?.deleted == false else { throw LibraryError.invalidRecord }
    try transaction { $0.localOverrides[id] = authentication }
  }
  public func authentication(for id: UUID, passphrase: String = "", oneTimePassword: String? = nil)
    async throws -> (ConnectionBinding, SSHAuthentication)
  {
    let epoch = scopeEpoch
    guard let row = state.records[id], let record = row.record, !record.deleted,
      let binding = record.binding
    else { throw LibraryError.invalidRecord }
    guard row.conflict == nil else { throw LibraryError.conflict }
    let auth = state.localOverrides[id] ?? binding.authentication
    switch auth {
    case .password(let reference):
      if let oneTimePassword { return (binding, .password(oneTimePassword)) }
      guard let reference else { throw LibraryError.missingCredential }
      try checkReference(reference)
      return (binding, .password(try vault.read(reference)))
    case .identity(let identityID):
      guard let identityRow = state.records[identityID], identityRow.conflict == nil,
        let key = identityRow.record, !key.deleted, let identity = key.identity
      else {
        throw LibraryError.identityMissing
      }
      try checkReference(identity.secret)
      let authentication = SSHAuthentication.ed25519(
        openSSH: try vault.read(identity.secret), passphrase: passphrase)
      let credentials = try await Task.detached {
        try SSHCredentials(authentication: authentication)
      }.value
      guard epoch == scopeEpoch else { throw LibraryError.accountChanged }
      guard credentials.publicKey == identity.publicKey else {
        throw LibraryError.fingerprintMismatch
      }
      return (binding, authentication)
    }
  }
  private func checkReference(_ reference: CredentialReference) throws {
    guard reference.ownerScope == scope else { throw LibraryError.accountChanged }
  }
  public func credentialStatus(for row: StoredRecord) -> String {
    guard let record = row.record else { return "Requires a newer app version" }
    if row.conflict != nil { return "Changes need review" }
    var reference = record.identity?.secret
    if let binding = record.binding {
      switch state.localOverrides[record.id] ?? binding.authentication {
      case .password(let value): reference = value
      case .identity(let id):
        guard let key = state.records[id], key.conflict == nil, key.record?.deleted == false else {
          return "SSH identity needs attention"
        }
        reference = key.record?.identity?.secret
      }
    }
    guard let reference else { return "Ask for password when connecting" }
    do {
      try checkReference(reference)
      _ = try vault.read(reference)
      return reference.storage == .account
        ? "Credential available · encrypted account sync" : "Credential available · this device"
    } catch LibraryError.missingCredential {
      return "Credential not available on this device"
    } catch LibraryError.locked { return "Unlock this device to access Keychain" } catch {
      return "Credential needs attention"
    }
  }

  /// A deliberate copy, never an automatic migration on login or account switch.
  public func copyLocalConnectionsToAccount() throws {
    try ensureEditable()
    guard let accountScope, scope == accountScope else { throw LibraryError.accountChanged }
    let local = try store.read(scope: "local")
    let live = local.records.values.compactMap(\.record).filter { !$0.deleted }
    let ids = Dictionary(uniqueKeysWithValues: live.map { ($0.id, UUID()) })
    var copied: [LibraryRecord] = []
    for var record in live {
      record.id = ids[record.id]!
      record.revision = UUID()
      if let identity = record.identity {
        let ref = try newReference(kind: .privateKey, storage: .device)
        try vault.insert(vault.read(identity.secret), reference: ref)
        record.identity?.secret = ref
      }
      if var binding = record.binding {
        switch binding.authentication {
        case .password(let old):
          if let old {
            binding.authentication = .password(try savePassword(vault.read(old), storage: .device))
          }
        case .identity(let old):
          if let new = ids[old] { binding.authentication = .identity(new) }
        }
        record.binding = binding
      }
      copied.append(record)
    }
    try transaction { state in
      for record in copied { state.records[record.id] = try StoredRecord(record) }
    }
    enqueueChanges()
  }

}
