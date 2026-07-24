import SwiftUI

/// Config screen -- account list, switch, add, logout.
/// Presented as a `.sheet` from `AppRootView`. Wraps content in its own
/// `NavigationStack` so that `SettingsView` can push within the sheet.
/// UX-67 through UX-70.
struct ConfigView: View {
    @StateObject private var viewModel = ConfigViewModel()
    /// Observes the user's theme color so the profile bubble background
    /// reflects the current theme (UX-48). See `WoowTheme.swift`.
    @ObservedObject private var theme = WoowTheme.shared
    let onBackClick: () -> Void
    let onSettingsClick: () -> Void
    let onAddAccountClick: () -> Void
    /// Called after the CURRENT account is logged out. The `Bool` is `true` when another account was
    /// promoted (stay authenticated on the main screen) and `false` when no accounts remain (return
    /// to the login screen).
    let onLogout: (Bool) -> Void

    @State private var showLogoutAlert = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                // Active account
                if let account = viewModel.activeAccount {
                    Section {
                        HStack(spacing: 12) {
                            Text(String(account.displayName.prefix(1)).uppercased())
                                .font(.title2).fontWeight(.bold)
                                .frame(width: 50, height: 50)
                                .background(theme.primaryColor.opacity(0.2))
                                .clipShape(Circle())
                            VStack(alignment: .leading) {
                                Text(account.displayName).font(.headline)
                                Text(account.username).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Settings
                Section {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                // Other accounts
                if viewModel.accounts.count > 1 {
                    Section("Switch Account") {
                        ForEach(viewModel.accounts.filter { !$0.isActive }) { account in
                            Button {
                                Task {
                                    let success = await viewModel.switchAccount(id: account.id)
                                    if success {
                                        onBackClick()
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(account.displayName)
                                    Text(account.serverUrl).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // Add account
                Section {
                    Button { onAddAccountClick() } label: {
                        Label("Add Account", systemImage: "plus.circle")
                    }
                }

                // Logout
                Section {
                    Button(role: .destructive) { showLogoutAlert = true } label: {
                        Label(String(localized: "logout_current_account"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle(String(localized: "configuration_title"))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBackClick) {
                        Image(systemName: "xmark")
                    }
                }
            }
            .alert(String(localized: "logout_current_account"), isPresented: $showLogoutAlert) {
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "logout_action"), role: .destructive) {
                    Task {
                        let stayAuthenticated = await viewModel.logout()
                        onLogout(stayAuthenticated)
                    }
                }
            } message: {
                // Account-aware copy: reassure when another account remains; warn when it's the last.
                if let other = viewModel.accounts.first(where: { !$0.isActive }) {
                    Text(String(format: String(localized: "logout_stay_signed_in"), other.displayName))
                } else {
                    Text(String(localized: "logout_last_account_message"))
                }
            }
            .onAppear { viewModel.loadAccounts() }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView(onBackClick: { showSettings = false })
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ConfigView(
        onBackClick: {},
        onSettingsClick: {},
        onAddAccountClick: {},
        onLogout: { _ in }
    )
}
