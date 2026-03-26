import CoreData

/// Core Data managed object for OdooAccount persistence.
/// Maps to Android's Room @Entity OdooAccount.
@objc(OdooAccountEntity)
public class OdooAccountEntity: NSManagedObject {
    @NSManaged public var id: String
    @NSManaged public var serverUrl: String
    @NSManaged public var database: String
    @NSManaged public var username: String
    @NSManaged public var displayName: String
    @NSManaged public var userId: Int32
    @NSManaged public var isActive: Bool
    @NSManaged public var createdAt: Date
}

extension OdooAccountEntity {

    /// Converts Core Data entity to domain model.
    func toDomainModel() -> OdooAccount {
        OdooAccount(
            id: id,
            serverUrl: serverUrl,
            database: database,
            username: username,
            displayName: displayName,
            userId: userId > 0 ? Int(userId) : nil,
            lastLogin: createdAt,
            isActive: isActive
        )
    }

    /// Updates entity from domain model.
    func update(from account: OdooAccount) {
        id = account.id
        serverUrl = account.serverUrl
        database = account.database
        username = account.username
        displayName = account.displayName
        userId = Int32(account.userId ?? 0)
        isActive = account.isActive
        createdAt = account.lastLogin
    }

    /// Fetch request for all accounts ordered by last login.
    static func fetchAllRequest() -> NSFetchRequest<OdooAccountEntity> {
        let request = NSFetchRequest<OdooAccountEntity>(entityName: "OdooAccountEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return request
    }

    /// Fetch request for the active account.
    static func fetchActiveRequest() -> NSFetchRequest<OdooAccountEntity> {
        let request = NSFetchRequest<OdooAccountEntity>(entityName: "OdooAccountEntity")
        request.predicate = NSPredicate(format: "isActive == YES")
        request.fetchLimit = 1
        return request
    }

    /// Fetch request by ID.
    static func fetchByIdRequest(id: String) -> NSFetchRequest<OdooAccountEntity> {
        let request = NSFetchRequest<OdooAccountEntity>(entityName: "OdooAccountEntity")
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return request
    }
}
