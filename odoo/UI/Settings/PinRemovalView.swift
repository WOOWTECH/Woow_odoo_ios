import SwiftUI

/// Confirms the current PIN before it is removed (LIVE-0927-4). Presented as a sheet from
/// SettingsView. Render-and-collect only: verification, failed-attempt counting and lockout all
/// happen in `SettingsViewModel.removePin(verifyingCurrentPin:)`, the same repository path as the
/// unlock screen, so this screen cannot be used to brute-force the PIN around the lockout.
struct PinRemovalView: View {
    /// Verifies `pin` and removes the PIN on success.
    let verifyAndRemove: (String) -> PinRemovalOutcome
    let onRemoved: () -> Void
    let onCancel: () -> Void

    @State private var pin: String = ""
    @State private var error: String?

    private let pinLength = PinHasher.pinLength

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Text(String(localized: "Enter Current PIN"))
                    .font(.title2.bold())

                HStack(spacing: 12) {
                    ForEach(0..<pinLength, id: \.self) { i in
                        Circle()
                            .fill(i < pin.count ? Color.primary : Color.gray.opacity(0.3))
                            .frame(width: 14, height: 14)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Enter Current PIN"))
                .accessibilityValue(Text(verbatim: "\(pin.count)/\(pinLength)"))

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Spacer()

                NumberPadView(
                    onNumberTap: { appendDigit($0) },
                    onDelete: { if !pin.isEmpty { pin.removeLast() } }
                )

                Spacer()
            }
            .padding()
            .navigationTitle(String(localized: "Remove PIN"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private func appendDigit(_ digit: String) {
        guard pin.count < pinLength, digit.count == 1, digit.allSatisfy(\.isNumber) else { return }
        pin += digit
        error = nil
        // Verify once per full entry, never per keystroke — a partial PIN would burn attempts.
        guard pin.count == pinLength else { return }
        let outcome = verifyAndRemove(pin)
        pin = ""
        if outcome == .removed {
            onRemoved()
        } else {
            error = outcome.errorMessage()
        }
    }
}

#Preview {
    PinRemovalView(verifyAndRemove: { _ in .incorrectPin }, onRemoved: {}, onCancel: {})
}
