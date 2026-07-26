import LocalAuthentication
import SwiftUI

/// Biometric authentication screen — Face ID / Touch ID.
/// UX-10 through UX-14: NO skip button.
/// Ported from Android: BiometricScreen.kt
struct BiometricView: View {
    @ObservedObject var authViewModel: AuthViewModel
    /// Observes the user's theme color so the icon + button tints reflect
    /// the current theme (UX-48). See `WoowTheme.swift`.
    @ObservedObject private var theme = WoowTheme.shared
    let onAuthSuccess: () -> Void
    let onUsePinClick: () -> Void
    /// Whether a PIN exists as a fallback. When false (`.biometricOnly`), the "Use PIN" button is
    /// hidden AND the system fallback / lockout paths must NOT route to a (nonexistent) PIN screen.
    let hasPin: Bool

    @State private var errorMessage: String?
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Fingerprint/Face icon
            Image(systemName: biometricIcon)
                .font(.system(size: 64))
                .foregroundStyle(theme.primaryColor)
                .scaleEffect(isAnimating ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.3), value: isAnimating)

            Text(String(localized: "biometric_login_title"))
                .font(.title2)
                .fontWeight(.bold)

            Text(String(localized: "biometric_subtitle"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Error message
            if let error = errorMessage {
                ErrorBannerView(message: error)
            }

            Spacer()

            // Retry biometric button
            Button {
                authenticate()
            } label: {
                HStack {
                    Image(systemName: biometricIcon)
                    Text(String(localized: "unlock_with") + " " + biometricName)
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primaryColor)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // Use PIN fallback — NO skip button (UX-14). Shown only when a PIN exists; in
            // `.biometricOnly` there is no PIN to fall back to, so the button is hidden.
            if hasPin {
                Button(String(localized: "use_pin_button")) {
                    onUsePinClick()
                }
                .foregroundStyle(.secondary)
            }

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

        // In `.biometricOnly` there is no PIN fallback: suppress the system fallback button so a
        // tap can't fire `.userFallback` and strand the user on a nonexistent PIN screen.
        if !hasPin {
            context.localizedFallbackTitle = ""
        }

        isAnimating = true

        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: String(localized: "biometric_reason")
        ) { success, authError in
            Task { @MainActor in
                isAnimating = false
                if success {
                    authViewModel.setAuthenticated(true)
                    onAuthSuccess()
                } else if let authError = authError as? LAError {
                    switch authError.code {
                    case .userCancel, .systemCancel:
                        break // User cancelled — stay on screen
                    case .userFallback:
                        // Only route to PIN when one exists; otherwise stay with a retryable error.
                        if hasPin { onUsePinClick() } else { errorMessage = String(localized: "error_biometric_failed") }
                    case .biometryLockout:
                        errorMessage = String(localized: "error_biometric_lockout")
                        // No PIN → do not route to a nonexistent PIN screen; the Retry button and
                        // (in `.setupRequired`) the device-passcode path remain the way forward.
                        if hasPin { onUsePinClick() }
                    default:
                        errorMessage = String(localized: "error_biometric_failed")
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    BiometricView(
        authViewModel: AuthViewModel(),
        onAuthSuccess: {},
        onUsePinClick: {},
        hasPin: true
    )
}
