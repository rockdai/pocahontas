import Foundation

public enum SecretKind: String, Codable, Sendable { case password, privateKey }
public enum SecretStorage: String, Codable, Sendable { case device, account }

/// A logical address, never a Keychain persistent reference or authentication material.
public struct CredentialReference: Codable, Equatable, Sendable {
  public var ownerScope: String
  public var id: UUID
  public var revision: UUID
  public var kind: SecretKind
  public var storage: SecretStorage
  public init(ownerScope: String, kind: SecretKind, storage: SecretStorage) {
    self.ownerScope = ownerScope
    self.kind = kind
    self.storage = storage
    id = UUID()
    revision = UUID()
  }
  public var account: String { "\(ownerScope)/\(id)/\(revision)/\(kind.rawValue)" }
  private enum CodingKeys: String, CodingKey { case ownerScope, id, revision, kind, storage }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(ownerScope, forKey: .ownerScope)
    try values.encode(id.uuidString.lowercased(), forKey: .id)
    try values.encode(revision.uuidString.lowercased(), forKey: .revision)
    try values.encode(kind, forKey: .kind)
    try values.encode(storage, forKey: .storage)
  }
}

public enum SavedAuthentication: Codable, Equatable, Sendable {
  case password(CredentialReference?)
  case identity(UUID)

  private enum CodingKeys: String, CodingKey { case type, reference, id }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(String.self, forKey: .type) {
    case "password": self = .password(try values.decodeIfPresent(CredentialReference.self, forKey: .reference))
    case "identity": self = .identity(try values.decode(UUID.self, forKey: .id))
    default: throw LibraryError.newerSchema
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .password(let reference):
      try values.encode("password", forKey: .type)
      try values.encodeIfPresent(reference, forKey: .reference)
    case .identity(let id):
      try values.encode("identity", forKey: .type)
      try values.encode(id.uuidString.lowercased(), forKey: .id)
    }
  }
}

/// Endpoint and authentication are one indivisible merge field.
public struct ConnectionBinding: Codable, Equatable, Sendable {
  public var host: String
  public var port: Int
  public var username: String
  public var authentication: SavedAuthentication
  public init(host: String, port: Int, username: String, authentication: SavedAuthentication) throws
  {
    let connection = try SSHConnection(host: host, port: port, username: username)
    self.host = connection.host
    self.port = connection.port
    self.username = connection.username
    self.authentication = authentication
  }
}

public struct IdentityMaterial: Codable, Equatable, Sendable {
  public var publicKey: String
  public var fingerprint: String
  public var secret: CredentialReference
  public var requiresPassphrase: Bool
  public init(publicKey: String, secret: CredentialReference, requiresPassphrase: Bool) throws {
    self.publicKey = publicKey
    self.secret = secret
    self.requiresPassphrase = requiresPassphrase
    fingerprint = try SSHFingerprint.sha256(publicKey: publicKey)
  }
}

/// Local metadata; shared secret values are encoded separately inside the encrypted snapshot.
public struct LibraryRecord: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable {
    case host = "HostProfile"
    case identity = "SSHIdentity"
  }
  public var schemaVersion = 1
  public var id = UUID()
  public var revision = UUID()
  public var kind: Kind
  public var name: String
  public var tags: [String] = []
  public var binding: ConnectionBinding?
  public var identity: IdentityMaterial?
  public var deleted = false
  public init(name: String, binding: ConnectionBinding) {
    kind = .host
    self.name = name
    self.binding = binding
  }
  public init(name: String, identity: IdentityMaterial) {
    kind = .identity
    self.name = name
    self.identity = identity
  }
  public init(tombstone id: UUID, kind: Kind) {
    self.id = id
    self.kind = kind
    name = ""
    deleted = true
  }
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(self)
  }
  public static func decode(_ data: Data) throws -> Self {
    struct Header: Decodable { var schemaVersion: Int }
    guard try JSONDecoder().decode(Header.self, from: data).schemaVersion == 1 else {
      throw LibraryError.newerSchema
    }
    let record = try JSONDecoder().decode(Self.self, from: data)
    guard
      record.deleted || (record.kind == .host && record.binding != nil && record.identity == nil)
        || (record.kind == .identity && record.identity != nil && record.binding == nil)
    else {
      throw LibraryError.invalidRecord
    }
    return record
  }
}

public struct RecordConflict: Codable, Equatable, Sendable {
  public var remote: LibraryRecord
  public var fields: [String]
}

public struct StoredRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var payload: Data
  public var base: Data?
  public var dirty: Bool
  public var conflict: RecordConflict?
  public var record: LibraryRecord? { try? LibraryRecord.decode(payload) }
  public var isReadOnly: Bool { record == nil }
  public init(_ record: LibraryRecord) throws {
    id = record.id
    payload = try record.encoded()
    dirty = true
  }
  init(id: UUID, payload: Data) {
    self.id = id
    self.payload = payload
    base = payload
    dirty = false
  }

  /// Pure three-way merge. Deletion wins; clocks never decide whose edit to discard.
  public mutating func receive(_ data: Data) throws {
    let remote: LibraryRecord
    do { remote = try LibraryRecord.decode(data) } catch LibraryError.newerSchema {
      // Retain an older unsent edit separately; never overwrite the unknown payload.
      if dirty, let local = record { conflict = RecordConflict(remote: local, fields: ["schema"]) }
      payload = data
      base = data
      dirty = false
      return
    }
    guard remote.id == id else { throw LibraryError.invalidRecord }
    guard let local = record else { throw LibraryError.newerSchema }
    let ancestor = base.flatMap { try? LibraryRecord.decode($0) }
    base = data
    if remote.deleted || !dirty {
      payload = data
      dirty = false
      conflict = nil
      return
    }
    if local.deleted {
      conflict = nil
      return
    }
    var merged = local
    var fields: [String] = []
    func merge<T: Equatable>(_ name: String, _ local: T, _ remote: T, _ base: T?) -> T {
      if local == remote { return local }
      if let base, local == base { return remote }
      if let base, remote == base { return local }
      fields.append(name)
      return local
    }
    merged.name = merge("name", local.name, remote.name, ancestor?.name)
    merged.tags = merge("tags", local.tags, remote.tags, ancestor?.tags)
    merged.binding = merge("connection", local.binding, remote.binding, ancestor.map(\.binding))
    merged.identity = merge("identity", local.identity, remote.identity, ancestor.map(\.identity))
    // A second fetch must not silently dismiss a conflict the user hasn't resolved.
    let unresolved = Set(fields).union(conflict?.fields ?? [])
    conflict =
      unresolved.isEmpty ? nil : RecordConflict(remote: remote, fields: unresolved.sorted())
    merged.revision = UUID()
    payload = try merged.encoded()
  }

  public mutating func acknowledge(_ data: Data) throws {
    let saved = try LibraryRecord.decode(data)
    guard saved.id == id else { throw LibraryError.invalidRecord }
    base = data
    // A user may have edited again while this particular revision was in flight.
    if record?.revision == saved.revision { dirty = false }
  }

  public mutating func resolve(useRemote: Bool) throws {
    guard var value = record, let conflict, !conflict.fields.contains("schema") else {
      throw LibraryError.newerSchema
    }
    if useRemote {
      for field in conflict.fields {
        switch field {
        case "name": value.name = conflict.remote.name
        case "tags": value.tags = conflict.remote.tags
        case "connection": value.binding = conflict.remote.binding
        case "identity": value.identity = conflict.remote.identity
        default: throw LibraryError.invalidRecord
        }
      }
    }
    value.revision = UUID()
    payload = try value.encoded()
    dirty = true
    self.conflict = nil
  }
}

public enum LibraryError: LocalizedError, Sendable {
  case newerSchema, invalidRecord, conflict, missingCredential, locked
  case unavailableKeychain(Int32)
  case accountChanged, identityMissing, fingerprintMismatch, recoveryRequired
  public var errorDescription: String? {
    switch self {
    case .newerSchema:
      "Update pocahontas to use this connection. Its original data has been preserved."
    case .invalidRecord: "This connection could not be read. Its original data has been preserved."
    case .conflict: "Review the conflicting changes before connecting or editing."
    case .missingCredential:
      "The credential is not available on this device. Retry later, enter it for this connection, or save a credential on this device."
    case .locked: "Unlock this device to access its Keychain, then try again."
    case .unavailableKeychain(let status):
      "Keychain is unavailable (\(status)). Unlock this device and check the app’s signing."
    case .accountChanged:
      "The account changed. Reopen the connection in the current library."
    case .identityMissing:
      "This SSH identity is unavailable. Choose another identity or use a credential for this connection."
    case .fingerprintMismatch: "This private key does not match the saved SSH identity."
    case .recoveryRequired:
      "Your local changes have been preserved. Review the library in Account & Sync."
    }
  }
}
