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
    /// Opaque tenant id from device registration. Optional — nil for accounts
    /// persisted before this attribute was added (lightweight migration).
    @NSManaged public var tenantId: String?
    /// ACCOUNT-scoped push routing key — the `woow.fcm.device` row id (P2-9).
    @NSManaged public var deviceId: String?
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
            isActive: isActive,
            tenantId: tenantId,
            deviceId: deviceId
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
        tenantId = account.tenantId
        deviceId = account.deviceId
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

    /// Fetch request by opaque tenant id (the push-routing key).
    ///
    /// ⚠️ Deliberately has **no `fetchLimit`** (story 10-1, P2-9). A `LIMIT 1` on a routing key IS
    /// the defect: `odoo_tenant_id` is the Odoo database name, and spec §4.3 ships every STB box
    /// with the same `POSTGRES_DB`, so two customer servers routinely produce two local accounts
    /// with an identical id. Taking the first row made the routing target depend on whatever order
    /// Core Data happened to return — a legitimate push from one server opening the other's account.
    /// The caller must COUNT and refuse on more than one; it cannot do that if the fetch has already
    /// discarded the evidence.
    /// Fetch by the ACCOUNT-scoped routing key. Unique per (fcm_token, user_id) by
    /// construction, which is the whole point of it — but still no `fetchLimit`, because
    /// a routing lookup must be able to detect a violated assumption rather than hide it.
    static func fetchByDeviceIdRequest(deviceId: String) -> NSFetchRequest<OdooAccountEntity> {
        let request = NSFetchRequest<OdooAccountEntity>(entityName: "OdooAccountEntity")
        request.predicate = NSPredicate(format: "deviceId == %@", deviceId)
        return request
    }

    static func fetchByTenantIdRequest(tenantId: String) -> NSFetchRequest<OdooAccountEntity> {
        let request = NSFetchRequest<OdooAccountEntity>(entityName: "OdooAccountEntity")
        request.predicate = NSPredicate(format: "tenantId == %@", tenantId)
        return request
    }
}
