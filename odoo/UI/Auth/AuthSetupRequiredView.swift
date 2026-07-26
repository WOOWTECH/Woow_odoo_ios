import LocalAuthentication
import SwiftUI

/// Fail-closed screen shown when App Lock is ON but no in-app method is usable — e.g. a
/// biometric-only lock whose Face ID permission was revoked in Settings, or after an OS
/// biometry-lockout. It must NEVER fall through to the unlocked app: the only way past it is the
/// **device passcode** (`.deviceOwnerAuthentication`, which also accepts biometric if it recovers).
/// The user is also told to set up an unlock method in Settings.
struct AuthSetupRequiredView: View {
    @ObservedObject var authViewModel: AuthViewModel
    @ObservedObject private var theme = WoowTheme.shared

    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(theme.primaryColor)

            Text(String(localized: "Unlock Required"))
                .font(.title2)
                .fontWeight(.bold)

            Text(String(localized: "No unlock method is available. Set up Face ID or a PIN in Settings, or unlock with your device passcode."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = errorMessage {
                ErrorBannerView(message: error)
            }

            Spacer()

            Button {
                authenticateWithDevicePasscode()
            } label: {
                Text(String(localized: "Unlock with Passcode"))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primaryColor)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer().frame(height: 40)
        }
        .padding(32)
        .frame(maxWidth: 500)
        .onAppear {
            authenticateWithDevicePasscode()
        }
    }

    private func authenticateWithDevicePasscode() {
        let context = LAContext()
        var error: NSError?

        // .deviceOwnerAuthentication = biometric OR device passcode. This is the fail-closed
        // fallback: even with no in-app method, the OS passcode still gates entry.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            errorMessage = String(localized: "No unlock method is available. Set up Face ID or a PIN in Settings, or unlock with your device passcode.")
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: String(localized: "biometric_reason")
        ) { success, _ in
            Task { @MainActor in
                if success {
                    authViewModel.setAuthenticated(true)
                }
            }
        }
    }
}

#Preview {
    AuthSetupRequiredView(authViewModel: AuthViewModel())
}
