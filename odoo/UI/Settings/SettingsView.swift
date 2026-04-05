import SwiftUI

/// Settings screen — appearance, security, data, about.
/// UX-47 through UX-57. Same section order as Android.
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    let onBackClick: () -> Void

    @State private var showColorPicker = false
    @State private var showPinSetup = false
    @State private var selectedColor = "#6183FC"

    var body: some View {
        Form {
            // Appearance
            Section("Appearance") {
                Button {
                    selectedColor = viewModel.settings.themeColor
                    showColorPicker = true
                } label: {
                    HStack {
                        Label("Theme Color", systemImage: "paintpalette")
                        Spacer()
                        Circle()
                            .fill(Color(hex: viewModel.settings.themeColor))
                            .frame(width: 28, height: 28)
                    }
                }

                Picker("Theme Mode", selection: Binding(
                    get: { viewModel.settings.themeMode },
                    set: { viewModel.updateThemeMode($0) }
                )) {
                    Text("System").tag(ThemeMode.system)
                    Text("Light").tag(ThemeMode.light)
                    Text("Dark").tag(ThemeMode.dark)
                }
            }

            // Security
            Section("Security") {
                Toggle("App Lock", isOn: Binding(
                    get: { viewModel.settings.appLockEnabled },
                    set: { viewModel.toggleAppLock($0) }
                ))

                if viewModel.settings.appLockEnabled {
                    Toggle("Biometric Unlock", isOn: Binding(
                        get: { viewModel.settings.biometricEnabled },
                        set: { viewModel.toggleBiometric($0) }
                    ))

                    Button {
                        showPinSetup = true
                    } label: {
                        HStack {
                            Label("PIN Code", systemImage: "lock.fill")
                            Spacer()
                            Text(viewModel.settings.pinEnabled ? "Change PIN" : "Set PIN")
                                .foregroundStyle(WoowColors.primaryBlue)
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(.primary)

                    if viewModel.settings.pinEnabled {
                        Button(role: .destructive) {
                            viewModel.removePin()
                        } label: {
                            Label("Remove PIN", systemImage: "trash")
                        }
                    }
                }
            }

            // Data & Storage
            Section("Data & Storage") {
                Button {
                    viewModel.clearCache()
                } label: {
                    HStack {
                        Label("Clear Cache", systemImage: "trash")
                        Spacer()
                        Text(viewModel.cacheSizeText)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            // About
            Section("About") {
                HStack {
                    Label("App Version", systemImage: "info.circle")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onBackClick) {
                    Image(systemName: "chevron.left")
                }
            }
        }
        .sheet(isPresented: $showColorPicker) {
            ColorPickerView(selectedColor: $selectedColor) { hex in
                viewModel.updateThemeColor(hex)
            }
        }
        .sheet(isPresented: $showPinSetup) {
            PinSetupView(
                isChangingPin: viewModel.settings.pinEnabled,
                onPinSet: { newPin in
                    viewModel.setPin(newPin)
                    showPinSetup = false
                },
                onCancel: { showPinSetup = false }
            )
        }
    }
}
