import Combine
import Foundation

/// Registration acknowledgement is not an APNs/FCM delivery health signal.
enum PushRegistrationStatus: String, Sendable, Equatable {
    case notRegistered = "push_status_not_registered"
    case registering = "push_status_registering"
    case acknowledged = "push_status_acknowledged"
    case notConfigured = "push_status_not_configured"
    case invalidResponse = "push_status_invalid_response"
    case signInRequired = "push_status_sign_in_required"
    case temporarilyUnavailable = "push_status_unavailable"

    var localizedDescription: String { NSLocalizedString(rawValue, comment: "Push registration state") }
}

@MainActor
final class PushRegistrationStatusStore: ObservableObject {
    static let shared = PushRegistrationStatusStore()
    private var operations: [String: UUID] = [:]

    func begin(accountId: String) -> UUID {
        let revision = UUID()
        operations[accountId] = revision
        return revision
    }

    func isCurrent(_ revision: UUID, accountId: String) -> Bool { operations[accountId] == revision }

    @Published private(set) var byAccount: [String: PushRegistrationStatus] = [:]

    func status(for accountId: String) -> PushRegistrationStatus {
        byAccount[accountId] ?? .notRegistered
    }

    func set(_ status: PushRegistrationStatus, for accountId: String) { byAccount[accountId] = status }
    func remove(accountId: String) {
        operations.removeValue(forKey: accountId)
        byAccount.removeValue(forKey: accountId)
    }
}
