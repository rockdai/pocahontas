import CoreData
import Foundation

public struct LibraryState: Codable, Sendable {
  public var records: [UUID: StoredRecord] = [:]
  public var localOverrides: [UUID: SavedAuthentication] = [:]
  public var engineState: Data?
  public var zoneKnown = false
  public var recoveryReason: String?
  public init() {}
}

/// One transactional snapshot per account. The library is small; a single Core Data
/// row makes the record/outbox/engine checkpoint atomic without a second journal.
@MainActor public final class LibraryStore {
  private let context: NSManagedObjectContext
  private let coordinator: NSPersistentStoreCoordinator
  public init(url: URL? = nil, inMemory: Bool = false) throws {
    let model = NSManagedObjectModel()
    let entity = NSEntityDescription()
    entity.name = "LibrarySnapshot"
    entity.managedObjectClassName = "NSManagedObject"
    let scope = NSAttributeDescription()
    scope.name = "scope"
    scope.attributeType = .stringAttributeType
    let data = NSAttributeDescription()
    data.name = "data"
    data.attributeType = .binaryDataAttributeType
    entity.properties = [scope, data]
    entity.uniquenessConstraints = [["scope"]]
    model.entities = [entity]
    coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let storeURL: URL?
    if inMemory {
      storeURL = nil
    } else {
      let directory =
        try url?.deletingLastPathComponent()
        ?? FileManager.default.url(
          for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("ConnectionLibrary", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      storeURL = url ?? directory.appendingPathComponent("Library.sqlite")
    }
    var options: [AnyHashable: Any] = [
      NSMigratePersistentStoresAutomaticallyOption: true,
      NSInferMappingModelAutomaticallyOption: true,
    ]
    #if os(iOS)
      options[NSPersistentStoreFileProtectionKey] =
        FileProtectionType.completeUntilFirstUserAuthentication
    #endif
    try coordinator.addPersistentStore(
      ofType: inMemory ? NSInMemoryStoreType : NSSQLiteStoreType,
      configurationName: nil, at: storeURL, options: options)
    context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
  }
  private func row(_ scope: String) throws -> NSManagedObject? {
    let request = NSFetchRequest<NSManagedObject>(entityName: "LibrarySnapshot")
    request.predicate = NSPredicate(format: "scope == %@", scope)
    request.fetchLimit = 1
    return try context.fetch(request).first
  }
  public func read(scope: String) throws -> LibraryState {
    guard let data = try row(scope)?.value(forKey: "data") as? Data else { return LibraryState() }
    // Decode failure is an error, never an empty replacement database.
    return try JSONDecoder().decode(LibraryState.self, from: data)
  }
  public func write(_ state: LibraryState, scope: String) throws {
    let data = try JSONEncoder().encode(state)
    do {
      let object =
        try row(scope)
        ?? NSEntityDescription.insertNewObject(forEntityName: "LibrarySnapshot", into: context)
      object.setValue(scope, forKey: "scope")
      object.setValue(data, forKey: "data")
      try context.save()
    } catch {
      context.rollback()
      throw error
    }
  }
}
