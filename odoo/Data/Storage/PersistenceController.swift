import CoreData

/// Core Data stack for persisting OdooAccount entities.
/// Uses NSPersistentContainer (iOS 16 compatible, not SwiftData).
final class PersistenceController: @unchecked Sendable {
    // @unchecked because NSPersistentContainer is not Sendable.
    // Thread safety: viewContext must only be accessed from @MainActor.
    // Use performBackground for background operations.

    static let shared = PersistenceController()

    /// In-memory store for SwiftUI previews and unit tests.
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        // Add sample data for previews
        let account = OdooAccountEntity(context: context)
        account.id = "preview-1"
        account.serverUrl = "demo.odoo.com"
        account.database = "demo"
        account.username = "admin"
        account.displayName = "Administrator"
        account.isActive = true
        account.createdAt = Date()
        try? context.save()
        return controller
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        // Build Core Data model programmatically (no .xcdatamodeld file needed)
        let model = Self.buildManagedObjectModel()
        container = NSPersistentContainer(name: "WoowOdoo", managedObjectModel: model)

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        }

        // Enable lightweight migration
        let description = container.persistentStoreDescriptions.first
        description?.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description?.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)

        container.loadPersistentStores { [weak self] _, error in
            if let error = error as NSError? {
                #if DEBUG
                fatalError("Core Data failed to load: \(error)")
                #else
                // Release: log error and flag for graceful degradation
                print("[ERROR] Core Data failed to load: \(error)")
                #endif
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Builds the Core Data model programmatically.
    /// Avoids dependency on .xcdatamodeld file — all in code.
    private static func buildManagedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = "OdooAccountEntity"
        entity.managedObjectClassName = "OdooAccountEntity"

        let idAttr = NSAttributeDescription()
        idAttr.name = "id"
        idAttr.attributeType = .stringAttributeType

        let serverUrlAttr = NSAttributeDescription()
        serverUrlAttr.name = "serverUrl"
        serverUrlAttr.attributeType = .stringAttributeType

        let databaseAttr = NSAttributeDescription()
        databaseAttr.name = "database"
        databaseAttr.attributeType = .stringAttributeType

        let usernameAttr = NSAttributeDescription()
        usernameAttr.name = "username"
        usernameAttr.attributeType = .stringAttributeType

        let displayNameAttr = NSAttributeDescription()
        displayNameAttr.name = "displayName"
        displayNameAttr.attributeType = .stringAttributeType

        let userIdAttr = NSAttributeDescription()
        userIdAttr.name = "userId"
        userIdAttr.attributeType = .integer32AttributeType
        userIdAttr.defaultValue = 0

        let isActiveAttr = NSAttributeDescription()
        isActiveAttr.name = "isActive"
        isActiveAttr.attributeType = .booleanAttributeType
        isActiveAttr.defaultValue = false

        let createdAtAttr = NSAttributeDescription()
        createdAtAttr.name = "createdAt"
        createdAtAttr.attributeType = .dateAttributeType

        entity.properties = [idAttr, serverUrlAttr, databaseAttr, usernameAttr,
                            displayNameAttr, userIdAttr, isActiveAttr, createdAtAttr]

        model.entities = [entity]
        return model
    }
}
