import SwiftUI

/// PIN entry screen with custom number pad.
/// UX-15 through UX-24: lockout, shake animation, remaining attempts.
/// Ported from Android: PinScreen.kt
struct PinView: View {
    @ObservedObject var authViewModel: AuthViewModel
    /// Observes the user's theme color so the PIN-dot fill reflects the
    /// current theme (UX-48). See `WoowTheme.swift`.
    @ObservedObject private var theme = WoowTheme.shared
    let onPinVerified: () -> Void
    let onBackClick: () -> Void

    @State private var pin: String = ""
    @State private var error: String?
    @State private var isShaking = false
    @State private var isLockedOut = false
    @State private var lockoutTimer: Timer?

    private let pinLength = 6

    var body: some View {
        VStack(spacing: 0) {
            // Back button
            HStack {
                Button(action: onBackClick) {
                    Image(systemName: "chevron.left")
                        .font(.title3)
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
                        .fill(index < pin.count ? theme.primaryColor : Color.clear)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(index < pin.count ? theme.primaryColor : Color.gray.opacity(0.4), lineWidth: 2)
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

            if isLockedOut {
                let remaining = authViewModel.getLockoutRemainingSeconds()
                Text(String(format: String(localized: "lockout_timer_%lld"), remaining))
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.top, 8)
            }

            Spacer()

            // Number pad
            if !isLockedOut {
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
            checkLockout()
        }
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
            isLockedOut = true
            startLockoutTimer()
        }
    }

    private func checkLockout() {
        isLockedOut = authViewModel.isLockedOut()
        if isLockedOut {
            startLockoutTimer()
        }
    }

    private func startLockoutTimer() {
        lockoutTimer?.invalidate()
        lockoutTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if !authViewModel.isLockedOut() {
                isLockedOut = false
                lockoutTimer?.invalidate()
            }
        }
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
