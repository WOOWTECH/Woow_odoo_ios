import SwiftUI

/// PIN setup/change flow — enter (verify old if changing) → new → confirm.
/// Presented as a sheet from SettingsView. (G2)
///
/// The `.verifyOld` step calls `verifyCurrentPin`, which SettingsView wires to its own
/// `SettingsViewModel.authorizePinChange(verifyingCurrentPin:)` — the same ViewModel whose `setPin`
/// the new PIN is saved through, so the one-time authorization lands where it is checked.
struct PinSetupView: View {
    let isChangingPin: Bool
    /// Checks the current PIN (and, on `.accepted`, authorizes the change). Only called when
    /// `isChangingPin`.
    let verifyCurrentPin: (String) -> CurrentPinOutcome
    let onPinSet: (String) -> Void
    let onCancel: () -> Void

    enum Step {
        case verifyOld
        case enterNew
        case confirmNew
    }

    @State private var step: Step
    @State private var pin: String = ""
    @State private var newPin: String = ""
    @State private var error: String?
    /// Lockout countdown for the `.verifyOld` step; updates every second and clears itself.
    @StateObject private var lockout = PinLockoutCountdown()

    private let pinLength = PinHasher.pinLength

    init(
        isChangingPin: Bool,
        verifyCurrentPin: @escaping (String) -> CurrentPinOutcome,
        onPinSet: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.isChangingPin = isChangingPin
        self.verifyCurrentPin = verifyCurrentPin
        self.onPinSet = onPinSet
        self.onCancel = onCancel
        _step = State(initialValue: isChangingPin ? .verifyOld : .enterNew)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Text(titleText)
                    .font(.title2.bold())

                // Dot indicators
                HStack(spacing: 12) {
                    ForEach(0..<pinLength, id: \.self) { i in
                        Circle()
                            .fill(i < pin.count ? Color.primary : Color.gray.opacity(0.3))
                            .frame(width: 14, height: 14)
                    }
                }

                if let message = lockout.message() ?? error {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Spacer()

                // Number pad
                NumberPadView(
                    onNumberTap: { numberString in
                        if let digit = Int(numberString) {
                            appendDigit(digit)
                        }
                    },
                    onDelete: {
                        if !pin.isEmpty { pin.removeLast() }
                    }
                )

                Spacer()
            }
            .padding()
            .navigationTitle(isChangingPin ? String(localized: "Change PIN") : String(localized: "Set PIN"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .onDisappear { lockout.stop() }
    }

    private var titleText: String {
        switch step {
        case .verifyOld: return String(localized: "Enter Current PIN")
        case .enterNew: return String(localized: "Enter New PIN")
        case .confirmNew: return String(localized: "Confirm New PIN")
        }
    }

    private func appendDigit(_ digit: Int) {
        guard pin.count < pinLength else { return }
        pin += "\(digit)"
        error = nil

        // Every step (verify-old / enter-new / confirm-new) evaluates once the full 6-digit PIN is
        // entered — no intermediate verify. Verifying the old PIN at 4/5 digits would spuriously
        // increment the failed-attempt counter (the same false-lockout fixed in
        // AuthViewModel.enterPinDigit).
        if pin.count == pinLength {
            handlePinComplete()
        }
    }

    private func handlePinComplete() {
        switch step {
        case .verifyOld:
            let outcome = verifyCurrentPin(pin)
            pin = ""
            // Shared with CurrentPinPromptView: a lockout counts down every second (and clears when
            // it ends) instead of a one-off "Try again in 30s" that never moved.
            error = lockout.errorMessage(for: outcome)
            if pinSetupVerifyOldResult(for: outcome) == .advance {
                step = .enterNew
            }
        case .enterNew:
            newPin = pin
            pin = ""
            step = .confirmNew
        case .confirmNew:
            if pin == newPin {
                onPinSet(pin)
            } else {
                error = String(localized: "pins_dont_match")
                pin = ""
                step = .enterNew
                newPin = ""
            }
        }
    }
}

// MARK: - Verify-old step

/// What PinSetupView's `.verifyOld` step does after the current PIN is checked.
enum PinSetupVerifyOldResult: Equatable {
    case advance
    case stay(error: String)
}

/// `.accepted` advances to the new PIN; any refusal stays with `CurrentPinOutcome.errorMessage`, so
/// a lockout shows the unlock screen's countdown (`lockout_timer_%lld`) instead of "Incorrect PIN"
/// — during a lockout even the correct PIN is refused, and "Incorrect PIN" would tell the user the
/// right PIN is wrong.
func pinSetupVerifyOldResult(for outcome: CurrentPinOutcome, bundle: Bundle = .main) -> PinSetupVerifyOldResult {
    guard let message = outcome.errorMessage(bundle: bundle) else { return .advance }
    return .stay(error: message)
}

// MARK: - Preview

#Preview("Set New PIN") {
    PinSetupView(
        isChangingPin: false,
        verifyCurrentPin: { _ in .accepted },
        onPinSet: { _ in },
        onCancel: {}
    )
}

#Preview("Change Existing PIN") {
    PinSetupView(
        isChangingPin: true,
        verifyCurrentPin: { _ in .accepted },
        onPinSet: { _ in },
        onCancel: {}
    )
}
