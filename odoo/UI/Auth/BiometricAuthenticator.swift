import Foundation
import LocalAuthentication

/// Which biometry the device offers (drives the lock-screen icon + label without the View ever
/// touching `LocalAuthentication`).
enum BiometryKind: Equatable {
    case faceID
    case touchID
    case none
}

/// Outcome of a biometric evaluation, normalized so the ViewModel never imports `LAError`.
enum BiometricOutcome: Equatable {
    case success
    case userCancel          // user/system dismissed — stay on screen, no error
    case userFallback        // user tapped the system fallback (only meaningful when a PIN exists)
    case biometryLockout     // OS locked biometry after too many failures
    case unavailable         // cannot evaluate (no hardware / not enrolled / permission revoked)
    case failed(String)      // other failure, with a message
}

/// Wraps `LocalAuthentication` behind a protocol so the auth flow lives in the ViewModel and is
/// unit-testable with a fake. No View imports `LocalAuthentication`.
protocol BiometricAuthenticator {
    /// Biometric is available to evaluate right now (hardware + enrolled + permitted, not OS-locked).
    func canEvaluate() -> Bool
    /// The device's biometry kind, for the icon/label.
    var biometryKind: BiometryKind { get }
    /// Runs the biometric (Face/Touch ID) prompt.
    func evaluateBiometrics(reason: String) async -> BiometricOutcome
    /// Runs device-owner auth (biometric OR device passcode) — the fail-closed fallback.
    func evaluateDeviceOwnerAuth(reason: String) async -> Bool
}

/// Production implementation backed by a fresh `LAContext` per call (contexts are single-use).
final class LABiometricAuthenticator: BiometricAuthenticator {

    func canEvaluate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var biometryKind: BiometryKind {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    func evaluateBiometrics(reason: String) async -> BiometricOutcome {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return ok ? .success : .failed("")
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .systemCancel, .appCancel:
                return .userCancel
            case .userFallback:
                return .userFallback
            case .biometryLockout:
                return .biometryLockout
            default:
                return .failed(laError.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func evaluateDeviceOwnerAuth(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
