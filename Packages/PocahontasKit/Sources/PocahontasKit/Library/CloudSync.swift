import CloudKit
import Foundation

enum CloudRecordCodec {
  static func systemFields(_ record: CKRecord) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }
  static func record(_ row: StoredRecord, zone: CKRecordZone.ID) throws -> CKRecord {
    guard let value = row.record else { throw LibraryError.newerSchema }
    let record: CKRecord
    if let data = row.systemFields {
      let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
      decoder.requiresSecureCoding = true
      defer { decoder.finishDecoding() }
      guard let restored = CKRecord(coder: decoder) else { throw LibraryError.invalidRecord }
      record = restored
    } else {
      record = CKRecord(
        recordType: value.kind.rawValue,
        recordID: CKRecord.ID(recordName: value.id.uuidString, zoneID: zone))
    }
    record.encryptedValues["payload"] = row.payload
    return record
  }
  static func payload(_ record: CKRecord) throws -> (UUID, Data) {
    guard let id = UUID(uuidString: record.recordID.recordName),
      let data = record.encryptedValues["payload"] as? Data
    else { throw LibraryError.invalidRecord }
    struct Header: Decodable {
      var id: UUID
      var schemaVersion: Int
    }
    let header = try JSONDecoder().decode(Header.self, from: data)
    guard header.id == id else { throw LibraryError.invalidRecord }
    if header.schemaVersion == 1 {
      let value = try LibraryRecord.decode(data)
      guard value.kind.rawValue == record.recordType else { throw LibraryError.invalidRecord }
    }
    return (id, data)
  }
}

extension ConnectionLibrary: CKSyncEngineDelegate {
  func startEngine() async {
    guard engine == nil, let container, scope == accountScope, syncEnabled else { return }
    guard state.recoveryReason == nil else {
      syncStatus = LibraryError.recoveryRequired.localizedDescription
      return
    }
    do {
      let serialization = try state.engineState.map {
        try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
      }
      let configuration = CKSyncEngine.Configuration(
        database: container.privateCloudDatabase,
        stateSerialization: serialization, delegate: self)
      let newEngine = CKSyncEngine(configuration)
      engine = newEngine
      primed = false
      // Restored pending changes must not escape before we fetch the server's state.
      newEngine.state.remove(pendingRecordZoneChanges: newEngine.state.pendingRecordZoneChanges)
      newEngine.state.remove(pendingDatabaseChanges: newEngine.state.pendingDatabaseChanges)
      await syncNow()
    } catch { failPersistence(error) }
  }

  public func syncNow() async {
    guard let engine, syncEnabled, !isSyncing, !storageFailed, state.recoveryReason == nil else {
      return
    }
    isSyncing = true
    uploadBlocked = []
    syncStatus = "Syncing with iCloud…"
    do {
      try await engine.fetchChanges()
      guard self.engine === engine, !storageFailed, state.recoveryReason == nil else { return }
      primed = true
      if !state.zoneKnown {
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
      }
      enqueueChanges()
      try await engine.sendChanges()
      guard self.engine === engine else { return }
      lastSync = Date()
      if conflictCount > 0 {
        syncStatus = "Changes need review"
      } else if pendingCount == 0 {
        syncStatus = "Up to date"
      } else if syncStatus == "Syncing with iCloud…" {
        syncStatus = "Changes waiting to upload"
      }
    } catch {
      guard self.engine === engine else { return }
      handleCloudError(error)
    }
    if self.engine === engine { isSyncing = false }
  }

  func enqueueChanges() {
    guard let engine, primed, syncEnabled, !storageFailed, state.recoveryReason == nil else {
      return
    }
    let pending = state.records.values.filter {
      $0.dirty && !$0.isReadOnly && $0.conflict == nil && !uploadBlocked.contains($0.id)
    }
    .map {
      CKSyncEngine.PendingRecordZoneChange.saveRecord(
        CKRecord.ID(recordName: $0.id.uuidString, zoneID: Self.zoneID))
    }
    engine.state.add(pendingRecordZoneChanges: pending)
  }

  public func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    guard engine === syncEngine, primed, !storageFailed, state.recoveryReason == nil else {
      return nil
    }
    do {
      var records: [CKRecord] = []
      for change in syncEngine.state.pendingRecordZoneChanges
      where context.options.scope.contains(change) {
        guard case .saveRecord(let id) = change, let uuid = UUID(uuidString: id.recordName),
          let row = state.records[uuid], row.dirty, row.conflict == nil, !row.isReadOnly,
          !uploadBlocked.contains(uuid)
        else {
          syncEngine.state.remove(pendingRecordZoneChanges: [change])
          continue
        }
        records.append(try CloudRecordCodec.record(row, zone: Self.zoneID))
        if records.count == 100 { break }
      }
      return records.isEmpty ? nil : CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records)
    } catch {
      failPersistence(error)
      return nil
    }
  }

  public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    guard engine === syncEngine, !storageFailed else { return }
    do {
      switch event {
      case .stateUpdate(let update):
        let data = try JSONEncoder().encode(update.stateSerialization)
        try transaction { $0.engineState = data }
      case .accountChange(let change):
        switch change.changeType {
        case .signOut, .switchAccounts:
          // Invalidate immediately, before awaiting account lookup or cancellation.
          let old = try invalidateAccount()
          Task {
            await old?.cancelOperations()
            await self.checkAccount()
          }
        case .signIn:
          Task { await self.checkAccount() }
        @unknown default: break
        }
      case .fetchedDatabaseChanges(let changes):
        if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
          try requireRecovery(
            "The iCloud connection zone was removed. Your local copy is preserved.")
        }
        if changes.modifications.contains(where: { $0.zoneID == Self.zoneID }) {
          try transaction { $0.zoneKnown = true }
        }
      case .fetchedRecordZoneChanges(let changes):
        try transaction { state in
          for change in changes.modifications where change.record.recordID.zoneID == Self.zoneID {
            try Self.receive(change.record, into: &state)
          }
          // The app only publishes tombstones. Physical deletes imply external reset;
          // do not recreate those records from an offline cache.
          if changes.deletions.contains(where: { $0.recordID.zoneID == Self.zoneID }) {
            state.recoveryReason =
              "Records were removed outside pocahontas. Reload iCloud before resuming sync."
          }
        }
        if state.recoveryReason != nil {
          primed = false
          syncStatus = LibraryError.recoveryRequired.localizedDescription
        }
        enqueueChanges()
      case .sentRecordZoneChanges(let sent):
        try transaction { state in
          for record in sent.savedRecords where record.recordID.zoneID == Self.zoneID {
            let (id, data) = try CloudRecordCodec.payload(record)
            try state.records[id]?.acknowledge(
              data, systemFields: CloudRecordCodec.systemFields(record))
          }
          for failure in sent.failedRecordSaves where failure.record.recordID.zoneID == Self.zoneID
          {
            if failure.error.code == .serverRecordChanged {
              guard let server = failure.error.serverRecord else {
                throw LibraryError.invalidRecord
              }
              try Self.receive(server, into: &state)
            }
          }
        }
        for failure in sent.failedRecordSaves where failure.error.code != .serverRecordChanged {
          // CKSyncEngine owns transient backoff. Errors requiring user action stay
          // in the durable outbox but must not cause an immediate send loop.
          let transient: [CKError.Code] = [
            .networkFailure, .networkUnavailable, .requestRateLimited,
            .serviceUnavailable, .zoneBusy, .batchRequestFailed,
          ]
          if !transient.contains(failure.error.code),
            let id = UUID(uuidString: failure.record.recordID.recordName)
          {
            uploadBlocked.insert(id)
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)]
            )
          }
          handleCloudError(failure.error)
        }
        enqueueChanges()
      case .sentDatabaseChanges(let sent):
        if sent.savedZones.contains(where: { $0.zoneID == Self.zoneID }) {
          try transaction { $0.zoneKnown = true }
        }
        for failure in sent.failedZoneSaves { handleCloudError(failure.error) }
      case .didFetchRecordZoneChanges(let fetched):
        if let error = fetched.error, fetched.zoneID == Self.zoneID { handleCloudError(error) }
      case .didSendChanges:
        if state.recoveryReason == nil, pendingCount == 0 {
          lastSync = Date()
          syncStatus = "Up to date"
        }
      default: break
      }
    } catch { failPersistence(error) }
  }

  static func receive(_ record: CKRecord, into state: inout LibraryState) throws {
    let (id, data) = try CloudRecordCodec.payload(record)
    let fields = CloudRecordCodec.systemFields(record)
    if var existing = state.records[id] {
      try existing.receive(data, systemFields: fields)
      state.records[id] = existing
    } else {
      state.records[id] = StoredRecord(id: id, payload: data, systemFields: fields)
    }
  }
  func requireRecovery(_ message: String) throws {
    primed = false
    try transaction { $0.recoveryReason = message }
    syncStatus = "iCloud needs recovery"
  }
  func failPersistence(_ error: Error) {
    // Stop processing state tokens after ANY persistence/decode failure. Otherwise a
    // newer checkpoint could permanently skip records that never reached disk.
    // If the store still works, persist a visible recovery gate as well. This
    // covers a corrupt checkpoint or an unreadable encrypted server payload.
    var preserved = state
    preserved.recoveryReason =
      "Sync data could not be read or saved. Check available device storage. Reload iCloud only after reviewing the archived-copy recovery option."
    if !storageFailed, (try? store.write(preserved, scope: scope)) != nil { state = preserved }
    storageFailed = true
    primed = false
    let old = engine
    engine = nil
    isSyncing = false
    errorMessage = "Sync stopped to preserve your data. \(error.localizedDescription)"
    syncStatus = "Sync stopped · reopen after resolving the storage error"
    Task { await old?.cancelOperations() }
  }
  func handleCloudError(_ error: Error) {
    if let cloud = error as? CKError {
      if [.zoneNotFound, .userDeletedZone, .unknownItem].contains(cloud.code), state.zoneKnown {
        do {
          try requireRecovery(
            "The saved iCloud library is no longer available. Reload before uploading changes.")
        } catch { failPersistence(error) }
        return
      }
      if cloud.code == .notAuthenticated { Task { await self.checkAccount() } }
    }
    syncStatus = Self.syncError(error)
  }
  static func syncError(_ error: Error) -> String {
    guard let cloud = error as? CKError else { return "iCloud unavailable · retry when connected" }
    switch cloud.code {
    case .networkFailure, .networkUnavailable: return "Offline · changes saved on this device"
    case .quotaExceeded: return "iCloud storage is full · free space, then retry"
    case .requestRateLimited, .serviceUnavailable, .zoneBusy:
      return "iCloud is busy · changes will retry"
    case .notAuthenticated: return "Sign in to iCloud in system settings"
    case .permissionFailure, .badContainer, .missingEntitlement:
      return "iCloud access is not configured for this build"
    default: return "iCloud could not sync (\(cloud.errorCode)) · local changes are safe"
    }
  }

  /// Explicit recovery keeps the entire old snapshot in a separate local quarantine.
  /// Only a subsequent user-initiated copy can put old records back into iCloud.
  public func reloadFromCloud() async throws {
    guard scope == accountScope else { throw LibraryError.accountChanged }
    let oldScope = scope
    await stopEngine()
    try store.write(state, scope: "recovery-\(oldScope)-\(UUID())")
    try store.write(LibraryState(), scope: oldScope)
    state = LibraryState()
    storageFailed = false
    scopeEpoch += 1
    accountGeneration += 1
    syncEnabled = true
    await startEngine()
  }
}
