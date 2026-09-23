import SwiftUI

/// Settings screen — Appearance, Security, Language, Data, Help, About.
/// UX-47 through UX-57, UX-58, UX-82 (section order matches Android).
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    /// Observes the user's theme color so the section icons reflect the
    /// current theme (UX-48). See `WoowTheme.swift`.
    @ObservedObject private var theme = WoowTheme.shared
    let onBackClick: () -> Void

    @State private var showColorPicker = false
    @State private var showPinSetup = false
    @State private var selectedColor = "#6183FC"

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

                Text("Change language in iOS Settings")
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

                Text("\u{00A9} 2026 WoowTech")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
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
    static let websiteURL = "https://aiot.woowtech.io"
    static let websiteDisplayName = "aiot.woowtech.io"
    static let contactEmail = "woowtech@designsmart.com.tw"

    // Public compliance pages on the WOOW website. Each exists in a default (Chinese) and an
    // English ("-en") variant; `forLanguage` is the app's current UI localization
    // (`Bundle.main.preferredLocalizations.first`): English → "-en", anything else → default page.
    static let supportPath = "/odoo-support"
    static let privacyPolicyPath = "/odoo-privacy"
    static let accountDeletionPath = "/odoo-account-deletion"

    static func supportURL(forLanguage code: String?) -> String {
        localizedPageURL(supportPath, forLanguage: code)
    }

    static func privacyPolicyURL(forLanguage code: String?) -> String {
        localizedPageURL(privacyPolicyPath, forLanguage: code)
    }

    static func accountDeletionURL(forLanguage code: String?) -> String {
        localizedPageURL(accountDeletionPath, forLanguage: code)
    }

    static func localizedPageURL(_ path: String, forLanguage code: String?) -> String {
        let isEnglish = code.map { $0 == "en" || $0.hasPrefix("en-") || $0.hasPrefix("en_") } ?? false
        return websiteURL + path + (isEnglish ? "-en" : "")
    }
}
