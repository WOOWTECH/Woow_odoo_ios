import SwiftUI

/// Brand color picker with preset + accent + HEX input.
/// UX-48 through UX-52.
/// Ported from Android: SettingsScreen.kt ColorPickerDialog
struct ColorPickerView: View {
    @Binding var selectedColor: String
    let onApply: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var customHex: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Brand colors
                    Text(String(localized: "preset_colors"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(WoowColors.brandColors, id: \.self) { hex in
                            colorSwatch(hex: hex)
                        }
                    }

                    // Accent colors
                    Text(String(localized: "accent_colors")).font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(WoowColors.accentColors, id: \.self) { hex in
                            colorSwatch(hex: hex)
                        }
                    }

                    // Custom HEX
                    Text(String(localized: "custom_color")).font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        TextField("#RRGGBB", text: $customHex)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.allCharacters)
                            .onChange(of: customHex) { newValue in
                                let filtered = newValue.filter { "0123456789ABCDEFabcdef#".contains($0) }
                                if filtered != newValue { customHex = filtered }
                            }

                        if customHex.count >= 7 {
                            let hex = customHex.hasPrefix("#") ? customHex : "#\(customHex)"
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                                .onTapGesture { selectedColor = hex }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Select Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(selectedColor)
                        dismiss()
                    }
                }
            }
        }
    }

    private func colorSwatch(hex: String) -> some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: 36, height: 36)
            .overlay(
                Circle().stroke(
                    selectedColor.lowercased() == hex.lowercased() ? Color.primary : Color.gray.opacity(0.3),
                    lineWidth: selectedColor.lowercased() == hex.lowercased() ? 3 : 1
                )
            )
            .onTapGesture { selectedColor = hex }
    }
}

// MARK: - Preview

#Preview {
    ColorPickerView(
        selectedColor: .constant("#6183FC"),
        onApply: { _ in }
    )
}
