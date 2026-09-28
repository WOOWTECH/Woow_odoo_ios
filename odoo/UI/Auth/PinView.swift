import SwiftUI

/// PIN entry screen with custom number pad.
/// UX-15 through UX-24: lockout, shake animation, remaining attempts.
/// Ported from Android: PinScreen.kt
struct PinView: View {
    @ObservedObject var authViewModel: AuthViewModel
    /// Observes the user's theme color so the PIN-dot fill reflects the
    let onPinVerified: () -> Void
    let onBackClick: () -> Void
    /// Hidden when PIN is the only method (nothing to go back to); shown in biometric+PIN.
    var showBack: Bool = true

    @State private var pin: String = ""
    @State private var error: String?
    @State private var isShaking = false
    /// Lockout countdown, re-read from the repository every second (shared with the Settings PIN
    /// prompts). Its timer used to flip state only at expiry, so the shown seconds never moved.
    @StateObject private var lockout = PinLockoutCountdown()

    private let pinLength = PinHasher.pinLength

    var body: some View {
        VStack(spacing: 0) {
            // Back button — hidden when PIN is the only method (nothing to go back to).
            HStack {
                if showBack {
                    Button(action: onBackClick) {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                    }
                }
                Spacer()
            }
            .padding()

            Spacer().frame(height: 48)

            Text(String(localized: "enter_pin_title"))
                .font(.title2)
                .fontWeight(.bold)

            Text(String(localized: "enter_pin_subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            // PIN dots
            HStack(spacing: 16) {
                ForEach(0..<pinLength, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? WoowTheme.fixedBrandColor : Color.clear)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(index < pin.count ? WoowTheme.fixedBrandColor : Color.gray.opacity(0.4), lineWidth: 2)
                        )
                }
            }
            .offset(x: isShaking ? 10 : 0)
            .animation(.default.repeatCount(3, autoreverses: true).speed(6), value: isShaking)
            .padding(.top, 40)

            // Error / lockout message
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.top, 16)
            }

            if let countdown = lockout.message() {
                Text(countdown)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.top, 8)
            }

            Spacer()

            // Number pad
            if !lockout.isLockedOut {
                NumberPadView(
                    onNumberTap: { onNumberTap($0) },
                    onDelete: {
                        if !pin.isEmpty {
                            pin.removeLast()
                            error = nil
                        }
                    }
                )
            }

            Spacer().frame(height: 40)
        }
        .frame(maxWidth: 500)
        .onAppear {
            startLockoutCountdown()
        }
        .onDisappear { lockout.stop() }
    }

    // MARK: - Logic

    private func onNumberTap(_ number: String) {
        guard pin.count < pinLength else { return }
        error = nil

        let result = authViewModel.enterPinDigit(number, currentPin: &pin)
        switch result {
        case .needMoreDigits:
            break
        case .success:
            onPinVerified()
        case .wrongPin(let remaining):
            error = String(format: String(localized: "wrong_pin_%lld"), remaining)
            isShaking = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                isShaking = false
            }
        case .lockedOut:
            startLockoutCountdown()
        }
    }

    /// Keypad hidden and countdown shown while the repository reports a lockout. At least 1 s while
    /// locked: the whole seconds left round down to 0 in the lockout's last fraction of a second.
    private func startLockoutCountdown() {
        lockout.start(source: { [authViewModel] in
            authViewModel.isLockedOut() ? max(1, authViewModel.getLockoutRemainingSeconds()) : 0
        })
    }
}

// MARK: - Preview

#Preview {
    PinView(
        authViewModel: AuthViewModel(),
        onPinVerified: {},
        onBackClick: {}
    )
}
