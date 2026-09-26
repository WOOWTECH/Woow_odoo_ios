import SwiftUI

/// Settings screen — Appearance, Security, Language, Data, Help, About.
/// UX-47 through UX-57, UX-58, UX-82 (section order matches Android).
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    /// Observes the user's theme color so the section icons reflect the
    /// current theme (UX-48). See `WoowTheme.swift`.
    @ObservedObject private var theme = WoowTheme.shared
    @ObservedObject private var pushStatus = PushRegistrationStatusStore.shared
    @State private var pushAccountId: String?
    let accountRepository: AccountRepositoryProtocol = AccountRepository()
    let onBackClick: () -> Void

    @State private var showColorPicker = false
    @State private var showPinSetup = false
    @State private var selectedColor = AppSettings.defaultThemeColor

    var body: some View {
        Form {
            // ── Appearance ──
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

                // G6: Reduce Motion toggle
                Toggle("Reduce Motion", isOn: Binding(
                    get: { viewModel.settings.reduceMotion },
                    set: { viewModel.toggleReduceMotion($0) }
                ))
            }

            // ── Security ──
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
                            Text(viewModel.settings.pinEnabled ? String(localized: "Change PIN") : String(localized: "Set PIN"))
                                .foregroundStyle(theme.primaryColor)
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

            // ── Privacy ──
            Section(header: Text(String(localized: "settings_location_title"))) {
                Toggle(
                    String(localized: "settings_location_title"),
                    isOn: $viewModel.locationEnabled
                )
                Text(String(localized: "settings_location_description"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if PushDiagnosticsVisibility.isVisible(
                brand: AppBrand.current.code,
                hasActiveAccount: pushAccountId != nil,
                isDebugBuild: PushDiagnosticsVisibility.isDebugBuild
            ), let pushAccountId {
                Section("Push Registration") {
                    Text(pushStatus.status(for: pushAccountId).localizedDescription)
                    Text("Registration acknowledgement does not confirm notification delivery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // ── Language (G1) ──
            Section("Language") {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Label("Language", systemImage: "globe")
                        Spacer()
                        Text(viewModel.currentLanguageDisplayName)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(.primary)

                Text(AppBrand.current.localized("Change language in iOS Settings"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // ── Data & Storage ──
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

            // ── Help & Support (G4) ──
            // WOOW-hosted support / privacy / account-deletion pages (store requirement:
            // in-app privacy policy + account deletion). English UI → "-en" page variant.
            Section("Help & Support") {
                externalLinkRow(
                    "Support",
                    systemImage: "questionmark.circle",
                    url: SettingsConstants.supportURL(forLanguage: Bundle.main.preferredLocalizations.first)
                )
                externalLinkRow(
                    "Privacy Policy",
                    systemImage: "hand.raised",
                    url: SettingsConstants.privacyPolicyURL(forLanguage: Bundle.main.preferredLocalizations.first)
                )
                externalLinkRow(
                    "Delete Account",
                    systemImage: "person.crop.circle.badge.xmark",
                    url: SettingsConstants.accountDeletionURL(forLanguage: Bundle.main.preferredLocalizations.first)
                )
            }

            // ── About (G5) ──
            Section("About") {
                HStack {
                    Label("App Version", systemImage: "info.circle")
                    Spacer()
                    Text(viewModel.appVersion)
                        .foregroundStyle(.secondary)
                }

                Button {
                    if let url = URL(string: SettingsConstants.websiteURL) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Label("Visit Website", systemImage: "globe")
                        Spacer()
                        Text(SettingsConstants.websiteDisplayName)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Image(systemName: "arrow.up.forward")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(.primary)

                Button {
                    if let url = URL(string: "mailto:\(SettingsConstants.contactEmail)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Label("Contact Us", systemImage: "envelope")
                        Spacer()
                        Text(SettingsConstants.contactEmail)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .foregroundStyle(.primary)

                Text(AppBrand.current.signature)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear { pushAccountId = accountRepository.getActiveAccount()?.id }
        .onReceive(NotificationCenter.default.publisher(for: .activeAccountDidChange)) { _ in
            pushAccountId = accountRepository.getActiveAccount()?.id
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

    /// A Help & Support row that opens `url` in the system browser.
    private func externalLinkRow(_ title: LocalizedStringKey, systemImage: String, url: String) -> some View {
        Button {
            if let target = URL(string: url) {
                UIApplication.shared.open(target)
            }
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.primary)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SettingsView(onBackClick: {})
    }
}

/// Constants for Settings — URLs, email, display names.
/// Extracted for testability and single source of truth.
enum SettingsConstants {
    static let websiteURL = AppBrand.current.websiteURL
    static let websiteDisplayName = AppBrand.current.websiteHost
    static let contactEmail = AppBrand.current.contactEmail

    static func supportURL(forLanguage code: String?) -> String {
        AppBrand.current.pageURL(.support, language: code)
    }

    static func privacyPolicyURL(forLanguage code: String?) -> String {
        AppBrand.current.pageURL(.privacy, language: code)
    }

    static func accountDeletionURL(forLanguage code: String?) -> String {
        AppBrand.current.pageURL(.accountDeletion, language: code)
    }
}
