import CloudKit
import CryptoKit
import Foundation
import Observation

@MainActor @Observable public final class ConnectionLibrary {
  public internal(set) var state = LibraryState()
  public internal(set) var scope = "local"
  public internal(set) var accountScope: String?
  public internal(set) var syncEnabled = false
  public internal(set) var syncStatus = "Saved on this device"
  public internal(set) var lastSync: Date?
  public internal(set) var accountGeneration = 0
  public internal(set) var isSyncing = false
  public var errorMessage: String?
  public let cloudConfigured: Bool
  public let credentialStorageAvailable: Bool
  @ObservationIgnored let store: LibraryStore
  @ObservationIgnored let vault: any CredentialVault
  @ObservationIgnored let defaults: UserDefaults
  @ObservationIgnored var engine: CKSyncEngine?
  @ObservationIgnored var container: CKContainer?
  @ObservationIgnored var primed = false
  @ObservationIgnored var accountObserver: NSObjectProtocol?
  @ObservationIgnored var accountCheck = 0
  @ObservationIgnored var scopeEpoch = 0
  @ObservationIgnored var storageFailed = false
  @ObservationIgnored var uploadBlocked: Set<UUID> = []
  static let zoneID = CKRecordZone.ID(
    zoneName: "Connections-v1", ownerName: CKCurrentUserDefaultName)
  public static let containerID = "iCloud.com.rockdai.pocahontas"

  public init(
    store: LibraryStore, vault: any CredentialVault, cloudConfigured: Bool,
    credentialStorageAvailable: Bool = true, defaults: UserDefaults = .standard
  ) throws {
    self.store = store
    self.vault = vault
    self.cloudConfigured = cloudConfigured
    self.credentialStorageAvailable = credentialStorageAvailable
    self.defaults = defaults
    state = try store.read(scope: "local")
    // An old cloud account's cache is never displayed before checking the current account.
    if cloudConfigured {
      container = CKContainer(identifier: Self.containerID)
      accountObserver = NotificationCenter.default.addObserver(
        forName: .CKAccountChanged,
        object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in await self?.checkAccount() }
      }
    }
  }

  public var hosts: [StoredRecord] { visible(.host) }
  public var identities: [StoredRecord] { visible(.identity) }
  public var pendingCount: Int { state.records.values.filter(\.dirty).count }
  public var conflictCount: Int { state.records.values.filter { $0.conflict != nil }.count }
  public var unknownCount: Int { state.records.values.filter(\.isReadOnly).count }
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
    try transaction { try $0.records[id]?.resolve(useRemote: useRemote) }
    enqueueChanges()
  }
  public func savePassword(_ password: String, storage: SecretStorage) throws -> CredentialReference
  {
    let reference = try newReference(kind: .password, storage: storage)
    try vault.insert(password, reference: reference)
    return reference
  }
  public func importIdentity(
    name: String, privateKey: String, passphrase: String,
    storage: SecretStorage, replacing id: UUID? = nil
  ) async throws {
    let epoch = scopeEpoch
    let original = id.flatMap { state.records[$0]?.record }
    let credentials = try await Task.detached {
      try SSHCredentials(authentication: .ed25519(openSSH: privateKey, passphrase: passphrase))
    }.value
    guard epoch == scopeEpoch else { throw LibraryError.accountChanged }
    guard let publicKey = credentials.publicKey else { throw LibraryError.invalidRecord }
    let reference = try newReference(kind: .privateKey, storage: storage)
    try vault.insert(privateKey, reference: reference)
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
    guard !storageFailed else { throw LibraryError.recoveryRequired }
    guard credentialStorageAvailable else { throw LibraryError.unavailableKeychain(-34018) }
    if storage == .iCloud {
      guard cloudConfigured, let accountScope, scope == accountScope else {
        throw LibraryError.cloudNotConfigured
      }
    }
    return CredentialReference(ownerScope: scope, kind: kind, storage: storage)
  }
  public func setLocalAuthentication(_ authentication: SavedAuthentication?, for id: UUID) throws {
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
      return reference.storage == .iCloud
        ? "Credential available · iCloud Keychain" : "Credential available · this device"
    } catch LibraryError.missingCredential {
      return "Credential not available on this device"
    } catch LibraryError.locked { return "Unlock this device to access Keychain" } catch {
      return "Credential needs attention"
    }
  }

  /// A deliberate copy, never an automatic migration on login or account switch.
  public func copyLocalConnectionsToCloud() throws {
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

  public func selectLocalLibrary() async throws {
    await stopEngine()
    try switchScope("local")
    defaults.set("local", forKey: "library.selected")
    syncStatus = "Saved on this device"
  }
  public func enableSync() async throws {
    guard cloudConfigured else { throw LibraryError.cloudNotConfigured }
    await checkAccount(restore: false)
    guard let accountScope else { return }
    try switchScope(accountScope)
    defaults.set(accountScope, forKey: "library.selected")
    defaults.set(true, forKey: "library.sync.\(accountScope)")
    syncEnabled = true
    await startEngine()
  }
  public func disableSync() async {
    defaults.set(false, forKey: "library.sync.\(scope)")
    await stopEngine()
    syncStatus = "Sync paused · changes stay on this device"
  }
  func stopEngine() async {
    let previous = engine
    engine = nil
    primed = false
    syncEnabled = false
    isSyncing = false
    await previous?.cancelOperations()
  }
  func switchScope(_ next: String) throws {
    guard scope != next else { return }
    let loaded = try store.read(scope: next)
    scopeEpoch += 1
    accountGeneration += 1
    state = loaded
    scope = next
    lastSync = nil
    storageFailed = false
    uploadBlocked = []
  }
  /// Account-change invalidation is synchronous. A cancellation/network await must
  /// never leave the previous account's credentials available to a new connection.
  func invalidateAccount() throws -> CKSyncEngine? {
    let previous = engine
    engine = nil
    primed = false
    syncEnabled = false
    isSyncing = false
    accountScope = nil
    scopeEpoch += 1
    accountGeneration += 1
    state = LibraryState()
    scope = "local"
    lastSync = nil
    do {
      state = try store.read(scope: "local")
      return previous
    } catch {
      storageFailed = true
      errorMessage = "The local library could not be opened. Its original data has been preserved."
      Task { await previous?.cancelOperations() }
      throw error
    }
  }
  public func checkAccount(restore: Bool = true) async {
    guard let container else { return }
    accountCheck += 1
    let check = accountCheck
    do {
      let status = try await container.accountStatus()
      guard check == accountCheck else { return }
      switch status {
      case .available:
        let user = try await container.userRecordID()
        guard check == accountCheck else { return }
        let next =
          "icloud-"
          + SHA256.hash(data: Data(user.recordName.utf8)).map { String(format: "%02x", $0) }
          .joined()
        if let old = accountScope, old != next {
          let previous = try invalidateAccount()
          Task { await previous?.cancelOperations() }
        }
        accountScope = next
        if restore, defaults.string(forKey: "library.selected") == next {
          try switchScope(next)
          if defaults.bool(forKey: "library.sync.\(next)"), engine == nil {
            syncEnabled = true
            await startEngine()
          }
        }
        if scope == "local" { syncStatus = "iCloud available · using local library" }
      case .noAccount, .restricted:
        if accountScope != nil || scope != "local" || engine != nil {
          let previous = try invalidateAccount()
          Task { await previous?.cancelOperations() }
        }
        syncStatus =
          status == .noAccount
          ? "Sign in to iCloud in system settings" : "iCloud access is restricted"
      case .couldNotDetermine, .temporarilyUnavailable:
        syncStatus = "iCloud temporarily unavailable · local changes are safe"
      @unknown default: syncStatus = "iCloud is unavailable"
      }
    } catch {
      // Transport errors are not sign-out: keep the verified account and its cache.
      syncStatus = Self.syncError(error)
    }
  }
}
