import Foundation

public struct SharedCredential: Codable, Sendable {
  public var reference: CredentialReference
  public var value: String
}

public struct PendingUpload: Codable, Sendable {
  public var expectedUpdatedAt: String
  public var ciphertext: Data
  public var records: [LibraryRecord]
  public var editRevision: UUID
}

public struct VaultSnapshot: Sendable {
  public var records: [LibraryRecord]
  public var credentials: [SharedCredential]
  public init(records: [LibraryRecord] = [], credentials: [SharedCredential] = []) {
    self.records = records
    self.credentials = credentials
  }
  private struct Envelope: Codable { var schemaVersion = 1; var records: [Entry] }
  private struct Entry: Codable {
    var type: String
    var id: String
    var deleted: Bool?
    var revision: String?
    var name: String?
    var tags: [String]?
    var binding: ConnectionBinding?
    var identity: IdentityMaterial?
    var credential: SharedCredential?
  }
  public func encoded() throws -> Data {
    var entries = records.map { record -> Entry in
      let type = record.kind == .host ? "host" : "identity"
      if record.deleted { return Entry(type: type, id: record.id.uuidString.lowercased(), deleted: true) }
      return Entry(type: type, id: record.id.uuidString.lowercased(),
        revision: record.revision.uuidString.lowercased(), name: record.name,
        tags: record.tags, binding: record.binding, identity: record.identity)
    }
    entries += credentials.map { Entry(type: "credential",
      id: $0.reference.revision.uuidString.lowercased(), credential: $0) }
    entries.sort { ($0.type, $0.id) < ($1.type, $1.id) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(Envelope(records: entries))
  }
  public static func decode(_ data: Data, scope: String) throws -> VaultSnapshot {
    struct Header: Decodable { var schemaVersion: Int }
    guard try JSONDecoder().decode(Header.self, from: data).schemaVersion == 1 else { throw LibraryError.newerSchema }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    var result = VaultSnapshot(), seen = Set<String>(), recordIDs = Set<UUID>()
    for entry in envelope.records {
      guard let id = UUID(uuidString: entry.id), seen.insert(entry.type + "/" + id.uuidString).inserted else {
        throw AccountError.invalidData
      }
      if entry.type == "credential" {
        guard let credential = entry.credential, credential.reference.storage == .account,
          credential.reference.ownerScope == scope, credential.reference.revision == id,
          !credential.value.isEmpty, credential.value.utf8.count <= 65536,
          entry.deleted == nil, entry.binding == nil, entry.identity == nil else { throw AccountError.invalidData }
        result.credentials.append(credential)
        continue
      }
      guard entry.type == "host" || entry.type == "identity" else { throw LibraryError.newerSchema }
      guard recordIDs.insert(id).inserted else { throw AccountError.invalidData }
      let kind: LibraryRecord.Kind = entry.type == "host" ? .host : .identity
      if entry.deleted == true {
        guard entry.binding == nil, entry.identity == nil, entry.credential == nil,
          entry.name == nil, entry.tags == nil, entry.revision == nil else { throw AccountError.invalidData }
        result.records.append(LibraryRecord(tombstone: id, kind: kind))
        continue
      }
      guard let name = entry.name, let revision = entry.revision.flatMap(UUID.init(uuidString:)),
        let tags = entry.tags, entry.credential == nil else { throw AccountError.invalidData }
      var record: LibraryRecord
      if kind == .host, let binding = entry.binding, entry.identity == nil {
        _ = try SSHConnection(host: binding.host, port: binding.port, username: binding.username)
        record = LibraryRecord(name: name, binding: binding)
      } else if kind == .identity, let identity = entry.identity, entry.binding == nil {
        guard try SSHFingerprint.sha256(publicKey: identity.publicKey) == identity.fingerprint else { throw AccountError.invalidData }
        record = LibraryRecord(name: name, identity: identity)
      } else { throw AccountError.invalidData }
      record.id = id
      record.revision = revision
      record.tags = tags
      result.records.append(record)
    }
    for record in result.records where !record.deleted {
      var reference = record.identity?.secret
      if case .password(let password) = record.binding?.authentication { reference = password }
      if let reference {
        guard reference.ownerScope == scope,
          reference.kind == (record.kind == .identity ? .privateKey : .password) else { throw AccountError.invalidData }
        if reference.storage == .account {
          guard result.credentials.contains(where: { $0.reference == reference }) else { throw AccountError.invalidData }
        }
      }
    }
    return result
  }
}
