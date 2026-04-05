import LocalAuthentication
import SwiftUI

/// Biometric authentication screen — Face ID / Touch ID.
/// UX-10 through UX-14: NO skip button.
/// Ported from Android: BiometricScreen.kt
struct BiometricView: View {
    @ObservedObject var authViewModel: AuthViewModel
    let onAuthSuccess: () -> Void
    let onUsePinClick: () -> Void

    @State private var errorMessage: String?
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Fingerprint/Face icon
            Image(systemName: biometricIcon)
                .font(.system(size: 64))
                .foregroundStyle(WoowColors.primaryBlue)
                .scaleEffect(isAnimating ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.3), value: isAnimating)

            Text("Biometric Login")
                .font(.title2)
                .fontWeight(.bold)

            Text("Use Face ID or Touch ID to unlock")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Error message
            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Spacer()

            // Retry biometric button
            Button {
                authenticate()
            } label: {
                HStack {
                    Image(systemName: biometricIcon)
                    Text("Unlock with \(biometricName)")
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(WoowColors.primaryBlue)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // Use PIN fallback — NO skip button (UX-14)
            Button("Use PIN") {
                onUsePinClick()
            }
            .foregroundStyle(.secondary)

            Spacer().frame(height: 40)
        }
        .padding(32)
        .frame(maxWidth: 500)
        .onAppear {
            authenticate()
        }
    }

    // MARK: - Biometric

    private var biometricIcon: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .faceID ? "faceid" : "touchid"
    }

    private var biometricName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .faceID ? "Face ID" : "Touch ID"
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            errorMessage = String(localized: "error_biometric_unavailable")
            return
        }

        isAnimating = true

        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: String(localized: "biometric_reason")
        ) { success, authError in
            DispatchQueue.main.async {
                isAnimating = false
                if success {
                    authViewModel.setAuthenticated(true)
                    onAuthSuccess()
                } else if let authError = authError as? LAError {
                    switch authError.code {
                    case .userCancel, .systemCancel:
                        break // User cancelled — stay on screen
                    case .userFallback:
                        onUsePinClick()
                    case .biometryLockout:
                        errorMessage = String(localized: "error_biometric_lockout")
                        onUsePinClick()
                    default:
                        errorMessage = String(localized: "error_biometric_failed")
                    }
                }
            }
        }
    }
}
