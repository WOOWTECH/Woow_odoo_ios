import SwiftUI

/// PIN setup/change flow — enter (verify old if changing) → new → confirm.
/// Presented as a sheet from SettingsView. (G2)
struct PinSetupView: View {
    let isChangingPin: Bool
    let onPinSet: (String) -> Void
    let onCancel: () -> Void

    @StateObject private var viewModel = SettingsViewModel()

    enum Step {
        case verifyOld
        case enterNew
        case confirmNew
    }

    @State private var step: Step
    @State private var pin: String = ""
    @State private var newPin: String = ""
    @State private var error: String?

    private let pinLength = 6

    init(isChangingPin: Bool, onPinSet: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.isChangingPin = isChangingPin
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

                if let error {
                    Text(error)
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

        if pin.count == pinLength {
            handlePinComplete()
        }
    }

    private func handlePinComplete() {
        switch step {
        case .verifyOld:
            if viewModel.verifyPin(pin) {
                pin = ""
                step = .enterNew
            } else {
                error = String(localized: "incorrect_pin")
                pin = ""
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

// MARK: - Preview

#Preview("Set New PIN") {
    PinSetupView(
        isChangingPin: false,
        onPinSet: { _ in },
        onCancel: {}
    )
}

#Preview("Change Existing PIN") {
    PinSetupView(
        isChangingPin: true,
        onPinSet: { _ in },
        onCancel: {}
    )
}
