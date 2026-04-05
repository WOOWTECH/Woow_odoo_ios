import SwiftUI

/// PIN entry screen with custom number pad.
/// UX-15 through UX-24: lockout, shake animation, remaining attempts.
/// Ported from Android: PinScreen.kt
struct PinView: View {
    @ObservedObject var authViewModel: AuthViewModel
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

            Text("Enter PIN")
                .font(.title2)
                .fontWeight(.bold)

            Text("Enter your PIN to unlock")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            // PIN dots
            HStack(spacing: 16) {
                ForEach(0..<pinLength, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? WoowColors.primaryBlue : Color.clear)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(index < pin.count ? WoowColors.primaryBlue : Color.gray.opacity(0.4), lineWidth: 2)
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
                numberPad
            }

            Spacer().frame(height: 40)
        }
        .frame(maxWidth: 500)
        .onAppear {
            checkLockout()
        }
    }

    // MARK: - Number Pad

    private var numberPad: some View {
        VStack(spacing: 16) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 28) {
                    ForEach(1...3, id: \.self) { col in
                        let number = row * 3 + col
                        numberKey("\(number)")
                    }
                }
            }
            HStack(spacing: 28) {
                Spacer().frame(width: 76, height: 76)
                numberKey("0")
                deleteKey
            }
        }
    }

    private func numberKey(_ number: String) -> some View {
        Button {
            onNumberTap(number)
        } label: {
            Text(number)
                .font(.title)
                .fontWeight(.medium)
                .frame(width: 76, height: 76)
                .background(Color(.systemGray6))
                .clipShape(Circle())
        }
        .foregroundStyle(.primary)
    }

    private var deleteKey: some View {
        Button {
            if !pin.isEmpty {
                pin.removeLast()
                error = nil
            }
        } label: {
            Image(systemName: "delete.backward")
                .font(.title2)
                .frame(width: 76, height: 76)
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Logic

    private func onNumberTap(_ number: String) {
        guard pin.count < pinLength else { return }
        pin += number
        error = nil

        if pin.count >= 4 {
            if authViewModel.verifyPin(pin) {
                authViewModel.setAuthenticated(true)
                onPinVerified()
            } else {
                let remaining = authViewModel.getRemainingAttempts()
                if remaining > 0 {
                    error = String(format: String(localized: "wrong_pin_%lld"), remaining)
                    isShaking = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isShaking = false
                    }
                } else {
                    isLockedOut = true
                    startLockoutTimer()
                }
                pin = ""
            }
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
