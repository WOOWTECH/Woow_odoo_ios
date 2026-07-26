import SwiftUI

/// Biometric unlock screen — RENDER ONLY. It draws the state the `AuthViewModel` publishes and
/// forwards taps; it owns no `LocalAuthentication`, no `scenePhase`, and no auto-prompt logic. The
/// biometric prompt is auto-run by the ViewModel on `appDidBecomeActive` (once per lock); the button
/// here is an explicit *retry* only.
/// Ported from Android: BiometricScreen.kt
struct BiometricView: View {
    @ObservedObject private var theme = WoowTheme.shared

    let kind: BiometryKind
    /// True while the Face/Touch prompt is in flight.
    let prompting: Bool
    let error: String?
    /// Only shown in the biometric+PIN combination (no PIN → no escape button).
    let showUsePin: Bool
    let onRetry: () -> Void
    let onUsePin: () -> Void

    private var iconName: String { kind == .touchID ? "touchid" : "faceid" }
    private var biometryName: String { kind == .touchID ? "Touch ID" : "Face ID" }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: iconName)
                .font(.system(size: 64))
                .foregroundStyle(theme.primaryColor)
                .scaleEffect(prompting ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.3), value: prompting)

            Text(String(localized: "biometric_login_title"))
                .font(.title2)
                .fontWeight(.bold)

            Text(String(localized: "biometric_subtitle"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error {
                ErrorBannerView(message: error)
            }

            Spacer()

            // Explicit retry — the auto-prompt is driven by the ViewModel, not this button.
            Button {
                onRetry()
            } label: {
                HStack {
                    Image(systemName: iconName)
                    Text(String(localized: "unlock_with") + " " + biometryName)
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primaryColor)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .disabled(prompting)

            // "Use PIN" — only when a PIN exists (UX-14: no skip button).
            if showUsePin {
                Button(String(localized: "use_pin_button")) {
                    onUsePin()
                }
                .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 40)
        }
        .padding(32)
        .frame(maxWidth: 500)
    }
}

// MARK: - Preview

#Preview {
    BiometricView(kind: .faceID, prompting: false, error: nil, showUsePin: true, onRetry: {}, onUsePin: {})
}
