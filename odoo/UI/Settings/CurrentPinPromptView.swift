import SwiftUI

/// Asks for the current PIN before a PIN-gated Settings action — removing the PIN (LIVE-0927-4) or
/// turning App Lock off (Android f9a0207 parity). Presented as a sheet from SettingsView.
/// Render-and-collect only: verification, failed-attempt counting and lockout all happen in
/// `SettingsViewModel` (`removePin(verifyingCurrentPin:)` / `disableAppLock(verifyingCurrentPin:)`),
/// the same repository path as the unlock screen, so this screen cannot be used to brute-force the
/// PIN around the lockout.
struct CurrentPinPromptView: View {
    /// Navigation title naming the action being confirmed.
    let title: String
    /// Optional line under "Enter Current PIN" explaining why the PIN is asked for.
    var subtitle: String?
    /// Verifies `pin` and performs the action on success.
    let verify: (String) -> CurrentPinOutcome
    let onAccepted: () -> Void
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

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

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
            .navigationTitle(title)
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
        let outcome = verify(pin)
        pin = ""
        if outcome == .accepted {
            onAccepted()
        } else {
            error = outcome.errorMessage()
        }
    }
}

#Preview {
    CurrentPinPromptView(
        title: String(localized: "App Lock"),
        subtitle: String(localized: "app_lock_disable_pin_subtitle"),
        verify: { _ in .incorrectPin },
        onAccepted: {},
        onCancel: {}
    )
}
