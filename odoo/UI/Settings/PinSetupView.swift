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
                pinNumpad

                Spacer()
            }
            .padding()
            .navigationTitle(isChangingPin ? "Change PIN" : "Set PIN")
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
        case .verifyOld: return "Enter Current PIN"
        case .enterNew: return "Enter New PIN"
        case .confirmNew: return "Confirm New PIN"
        }
    }

    private var pinNumpad: some View {
        VStack(spacing: 12) {
            ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { digit in
                        Button {
                            appendDigit(digit)
                        } label: {
                            Text("\(digit)")
                                .font(.title)
                                .frame(width: 70, height: 70)
                                .background(Color.gray.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 24) {
                Color.clear.frame(width: 70, height: 70)
                Button {
                    appendDigit(0)
                } label: {
                    Text("0")
                        .font(.title)
                        .frame(width: 70, height: 70)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                Button {
                    if !pin.isEmpty { pin.removeLast() }
                } label: {
                    Image(systemName: "delete.backward")
                        .font(.title2)
                        .frame(width: 70, height: 70)
                }
                .buttonStyle(.plain)
            }
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
                error = "Incorrect PIN"
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
                error = "PINs don't match"
                pin = ""
                step = .enterNew
                newPin = ""
            }
        }
    }
}
