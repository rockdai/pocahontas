import Foundation

extension ConnectionLibrary {
  func assertEpoch(_ epoch: Int) throws {
    guard scopeEpoch == epoch, !Task.isCancelled else { throw LibraryError.accountChanged }
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
  }
  public func checkAccount() async {
    guard !restored else { return }
    restored = true
    do {
      guard let saved = try sessionStore?.read() else { return }
      guard saved.dataKey.count == 32, saved.salt.count == 32, UUID(uuidString: saved.userId) != nil else {
        throw AccountError.invalidData
      }
      try switchScope(saved.userId)
      accountScope = saved.userId
      accountEmail = saved.email
      session = saved
      syncEnabled = true
      await syncNow()
    } catch {
      restored = false
      errorMessage = error.localizedDescription
    }
  }
  func invalidateAccount() throws {
    queuedSync?.cancel()
    syncTask?.cancel()
    session = nil
    syncEnabled = false
    isSyncing = false
    scopeEpoch += 1
    accountGeneration += 1
    try sessionStore?.clear()
    syncStatus = "Sign in again · unsynced changes are kept"
  }
  public func signOut() throws {
    try invalidateAccount()
    accountScope = nil
    accountEmail = nil
    try switchScope("local")
    syncStatus = "Saved on this device"
  }
  public func requestCode(email: String, reset: Bool) async throws -> String {
    guard let api else { throw AccountError.notConfigured }
    return try await api.requestCode(email: email, reset: reset)
  }
  public func registerOrReset(email: String, password: String, codeId: String, code: String,
    reset: Bool, confirmDelete: Bool = false) async throws {
    guard !isAccountBusy else { throw AccountError.busy }
    guard let api, !reset || confirmDelete else { throw AccountError.notConfigured }
    try AccountCrypto.validatePassword(password)
    isAccountBusy = true
    defer { isAccountBusy = false }
    let epoch = scopeEpoch
    let keys = try await Task.detached {
      try AccountCrypto.derive(password: password, salt: AccountCrypto.randomSalt())
    }.value
    try assertEpoch(epoch)
    let encrypted = try AccountCrypto.encrypt(VaultSnapshot().encoded(), key: keys.dataKey)
    do {
      try await api.registerOrReset(codeId: codeId, code: code, keys: keys, ciphertext: encrypted, reset: reset)
    } catch {
      guard mayHaveCommitted(error) else { throw error }
    }
    try assertEpoch(epoch)
    let login = try await api.login(email: email, loginSecret: keys.loginSecret)
    try assertEpoch(epoch)
    try accept(login, email: email, keys: keys)
  }
  public func signIn(email: String, password: String) async throws {
    guard !isAccountBusy else { throw AccountError.busy }
    guard let api else { throw AccountError.notConfigured }
    isAccountBusy = true
    defer { isAccountBusy = false; scheduleSync() }
    await syncTask?.value
    let epoch = scopeEpoch
    let salt = try await api.salt(email: email)
    try assertEpoch(epoch)
    let keys = try await Task.detached { try AccountCrypto.derive(password: password, salt: salt) }.value
    try assertEpoch(epoch)
    let login = try await api.login(email: email, loginSecret: keys.loginSecret)
    try assertEpoch(epoch)
    try accept(login, email: email, keys: keys)
  }
  private func accept(_ login: AccountLogin, email: String, keys: AccountKeys) throws {
    guard login.userId == login.vault.userId, UUID(uuidString: login.userId) != nil,
      try Data(base64URL: login.vault.salt) == keys.salt else { throw AccountError.invalidData }
    let decoded = try decode(login.vault, key: keys.dataKey, userID: login.userId)
    var loaded = try store.read(scope: login.userId)
    if let old = loaded.passwordUpdatedAt, old != login.vault.passwordUpdatedAt {
      var archive = loaded.archiveScope
      if loaded.needsUpload || loaded.pendingUpload != nil || loaded.records.values.contains(where: \.dirty) {
        archive = "archive-\(login.userId)-\(UUID().uuidString)"
        try store.write(loaded, scope: archive!)
      }
      loaded = LibraryState()
      loaded.archiveScope = archive
      if archive != nil { loaded.recoveryReason = "Your password changed. Unsynced edits were saved separately and will not upload automatically." }
    }
    try importCredentials(decoded, into: &loaded)
    try merge(decoded, remote: login.vault, into: &loaded)
    try store.write(loaded, scope: login.userId)
    let saved = AccountSession(email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      userId: login.userId, token: login.token, expiresAt: login.expiresAt,
      passwordUpdatedAt: login.vault.passwordUpdatedAt, salt: keys.salt, dataKey: keys.dataKey)
    try sessionStore?.save(saved)
    queuedSync?.cancel()
    scopeEpoch += 1
    accountGeneration += 1
    state = loaded
    scope = login.userId
    session = saved
    accountScope = login.userId
    accountEmail = saved.email
    syncEnabled = true
    storageFailed = false
    restored = true
    syncStatus = conflictCount > 0 ? "Review conflicting changes" : "Account unlocked · ready to sync"
  }
  private func decode(_ remote: RemoteVault, key: Data, userID: String) throws -> VaultSnapshot {
    guard remote.userId == userID, Self.date(remote.updatedAt) != nil,
      Self.date(remote.passwordUpdatedAt) != nil else { throw AccountError.invalidData }
    let plaintext = try AccountCrypto.decrypt(Data(base64URL: remote.ciphertext), key: key)
    return try VaultSnapshot.decode(plaintext, scope: userID)
  }
  static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
  }
  private func importCredentials(_ snapshot: VaultSnapshot, into state: inout LibraryState) throws {
    for value in snapshot.credentials {
      try vault.insert(value.value, reference: value.reference)
      state.sharedCredentials[value.reference.revision] = value.reference
    }
  }
  private func merge(_ snapshot: VaultSnapshot, remote: RemoteVault, into state: inout LibraryState) throws {
    let remoteIDs = Set(snapshot.records.map(\.id))
    for row in state.records.values where row.base != nil && !remoteIDs.contains(row.id) {
      throw AccountError.invalidData
    }
    for record in snapshot.records {
      let bytes = try record.encoded()
      if var row = state.records[record.id] {
        guard row.record?.kind == record.kind else { throw AccountError.invalidData }
        try row.receive(bytes)
        state.records[record.id] = row
      } else { state.records[record.id] = StoredRecord(id: record.id, payload: bytes) }
    }
    state.remoteUpdatedAt = remote.updatedAt
    state.passwordUpdatedAt = remote.passwordUpdatedAt
    let remoteCredentials = Set(snapshot.credentials.map { $0.reference.revision })
    state.needsUpload = state.records.values.contains(where: \.dirty)
      || state.sharedCredentials.keys.contains { !remoteCredentials.contains($0) }
    state.blockedVault = nil
  }
  private func snapshot() throws -> VaultSnapshot {
    guard state.blockedVault == nil, unknownCount == 0 else { throw LibraryError.newerSchema }
    guard conflictCount == 0 else { throw LibraryError.conflict }
    return VaultSnapshot(records: state.records.values.compactMap(\.record),
      credentials: try state.sharedCredentials.values.map {
        SharedCredential(reference: $0, value: try vault.read($0))
      })
  }
  func enqueueChanges() {
    do {
      try transaction { $0.needsUpload = true; $0.editRevision = UUID() }
      scheduleSync()
    } catch { failPersistence(error) }
  }
  func scheduleSync() {
    guard syncEnabled, session != nil, !isAccountBusy else { return }
    queuedSync?.cancel()
    queuedSync = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      await self?.syncNow()
    }
  }
  public func syncNow() async {
    if let syncTask { await syncTask.value; return }
    guard syncEnabled, session != nil, !isAccountBusy, !storageFailed, state.blockedVault == nil else { return }
    let epoch = scopeEpoch
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      isSyncing = true
      do {
        try await synchronize(epoch: epoch)
      } catch AccountError.signedOut {
        if epoch == scopeEpoch {
          do { try invalidateAccount() } catch { errorMessage = error.localizedDescription }
        }
      } catch {
        if epoch == scopeEpoch {
          syncStatus = error.localizedDescription
          if !(error is URLError) { errorMessage = error.localizedDescription }
        }
      }
      if epoch == scopeEpoch { isSyncing = false }
    }
    syncTask = task
    await task.value
    syncTask = nil
  }
  private func synchronize(epoch: Int) async throws {
    guard let api, let session else { return }
    for _ in 0..<3 {
      try assertEpoch(epoch)
      if let pending = state.pendingUpload {
        do {
          let updated = try await api.save(ciphertext: pending.ciphertext,
            expectedUpdatedAt: pending.expectedUpdatedAt, token: session.token)
          try assertEpoch(epoch)
          guard Self.date(updated) != nil else { throw AccountError.invalidData }
          try transaction { state in
            for record in pending.records { try state.records[record.id]?.acknowledge(record.encoded()) }
            state.remoteUpdatedAt = updated
            state.pendingUpload = nil
            state.needsUpload = state.editRevision != pending.editRevision || state.records.values.contains(where: \.dirty)
          }
          if !state.needsUpload { lastSync = Date(); syncStatus = "Synced"; return }
        } catch AccountError.conflict {
          try assertEpoch(epoch)
          try transaction { $0.pendingUpload = nil }
        }
      }
      let remote = try await api.vault(token: session.token)
      try assertEpoch(epoch)
      guard remote.passwordUpdatedAt == session.passwordUpdatedAt else { throw AccountError.signedOut }
      guard try Data(base64URL: remote.salt) == session.salt else { throw AccountError.invalidData }
      let decoded: VaultSnapshot
      do { decoded = try decode(remote, key: session.dataKey, userID: session.userId) }
      catch LibraryError.newerSchema {
        try transaction { $0.blockedVault = remote }
        throw LibraryError.newerSchema
      }
      var next = state
      try importCredentials(decoded, into: &next)
      try merge(decoded, remote: remote, into: &next)
      try store.write(next, scope: scope)
      state = next
      if conflictCount > 0 { syncStatus = "Review conflicting changes"; return }
      if !state.needsUpload { lastSync = Date(); syncStatus = "Synced"; return }
      let payload = try snapshot()
      let encrypted = try AccountCrypto.encrypt(payload.encoded(), key: session.dataKey)
      try transaction { $0.pendingUpload = PendingUpload(expectedUpdatedAt: remote.updatedAt,
        ciphertext: encrypted, records: payload.records, editRevision: $0.editRevision) }
    }
    syncStatus = "Changes queued · syncing again shortly"
    scheduleSync()
  }
  public func changePassword(oldPassword: String, newPassword: String) async throws {
    guard !isAccountBusy else { throw AccountError.busy }
    guard let api, let previous = session else { throw AccountError.signedOut }
    try AccountCrypto.validatePassword(newPassword)
    isAccountBusy = true
    defer { isAccountBusy = false; scheduleSync() }
    await syncTask?.value
    let epoch = scopeEpoch
    try await synchronize(epoch: epoch)
    let payload = try snapshot()
    guard let updated = state.remoteUpdatedAt else { throw AccountError.invalidData }
    let (old, keys) = try await Task.detached {
      (try AccountCrypto.derive(password: oldPassword, salt: previous.salt),
       try AccountCrypto.derive(password: newPassword, salt: AccountCrypto.randomSalt()))
    }.value
    try assertEpoch(epoch)
    let encrypted = try AccountCrypto.encrypt(payload.encoded(), key: keys.dataKey)
    do {
      try await api.changePassword(oldSecret: old.loginSecret, keys: keys, ciphertext: encrypted,
        expectedUpdatedAt: updated, expectedPasswordUpdatedAt: previous.passwordUpdatedAt, token: previous.token)
    } catch {
      guard mayHaveCommitted(error) else { throw error }
    }
    try assertEpoch(epoch)
    let login = try await api.login(email: previous.email, loginSecret: keys.loginSecret)
    try assertEpoch(epoch)
    try finishPasswordChange(login, email: previous.email, keys: keys)
  }
  private func finishPasswordChange(_ login: AccountLogin, email: String, keys: AccountKeys) throws {
    _ = try decode(login.vault, key: keys.dataKey, userID: login.userId)
    // This device froze edits and submitted them with the password change.
    try transaction { state in
      state.passwordUpdatedAt = login.vault.passwordUpdatedAt
      state.pendingUpload = nil
      for id in state.records.keys {
        if let record = state.records[id]?.record { try state.records[id]?.acknowledge(record.encoded()) }
      }
      state.needsUpload = false
    }
    try accept(login, email: email, keys: keys)
  }
  private func mayHaveCommitted(_ error: Error) -> Bool {
    if error is URLError { return true }
    if case AccountError.response(let status, _) = error { return status >= 500 }
    return false
  }
  public func deleteAccount(password: String) async throws {
    guard !isAccountBusy else { throw AccountError.busy }
    guard let api, let session else { throw AccountError.signedOut }
    isAccountBusy = true
    defer { isAccountBusy = false }
    await syncTask?.value
    let epoch = scopeEpoch
    let keys = try await Task.detached { try AccountCrypto.derive(password: password, salt: session.salt) }.value
    try assertEpoch(epoch)
    try await api.deleteAccount(loginSecret: keys.loginSecret, token: session.token)
    try assertEpoch(epoch)
    try store.write(LibraryState(), scope: scope)
    try signOut()
  }
  public func archivedRecords() throws -> [LibraryRecord] {
    try archives().flatMap { $0.records.values.filter(\.dirty).compactMap(\.record) }
  }
  private func archives() throws -> [LibraryState] {
    var next = state.archiveScope, visited = Set<String>(), result: [LibraryState] = []
    while let scope = next {
      guard visited.insert(scope).inserted else { throw AccountError.invalidData }
      let saved = try store.read(scope: scope)
      result.append(saved)
      next = saved.archiveScope
    }
    return result
  }
  public func copyArchivedChangesToLocal() throws {
    try ensureEditable()
    var local = try store.read(scope: "local")
    func copy(_ old: CredentialReference) throws -> CredentialReference {
      let ref = CredentialReference(ownerScope: "local", kind: old.kind, storage: .device)
      try vault.insert(vault.read(old), reference: ref)
      return ref
    }
    for original in try archives() {
      let records = original.records.values.compactMap(\.record).filter { !$0.deleted }
      let ids = Dictionary(uniqueKeysWithValues: records.map { ($0.id, UUID()) })
      for var record in records {
        record.id = ids[record.id]!
        record.revision = UUID()
        if let identity = record.identity { record.identity?.secret = try copy(identity.secret) }
        if case .password(let ref) = record.binding?.authentication, let ref {
          record.binding?.authentication = .password(try copy(ref))
        } else if case .identity(let id) = record.binding?.authentication, let mapped = ids[id] {
          record.binding?.authentication = .identity(mapped)
        }
        local.records[record.id] = try StoredRecord(record)
      }
    }
    try store.write(local, scope: "local")
    try transaction { $0.archiveScope = nil; $0.recoveryReason = nil }
  }
  func failPersistence(_ error: Error) {
    storageFailed = true
    syncEnabled = false
    errorMessage = "The library could not be saved. Existing data has been kept. \(error.localizedDescription)"
  }
}
