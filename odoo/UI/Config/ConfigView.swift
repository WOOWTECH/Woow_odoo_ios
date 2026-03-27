import SwiftUI

/// Config screen — account list, switch, add, logout.
/// UX-67 through UX-70.
struct ConfigView: View {
    @StateObject private var viewModel = ConfigViewModel()
    let onBackClick: () -> Void
    let onSettingsClick: () -> Void
    let onAddAccountClick: () -> Void
    let onLogout: () -> Void

    @State private var showLogoutAlert = false

    var body: some View {
        List {
            // Active account
            if let account = viewModel.activeAccount {
                Section {
                    HStack(spacing: 12) {
                        Text(String(account.displayName.prefix(1)).uppercased())
                            .font(.title2).fontWeight(.bold)
                            .frame(width: 50, height: 50)
                            .background(WoowColors.primaryBlue.opacity(0.2))
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
                Button { onSettingsClick() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }

            // Other accounts
            if viewModel.accounts.count > 1 {
                Section("Switch Account") {
                    ForEach(viewModel.accounts.filter { !$0.isActive }) { account in
                        Button {
                            Task { _ = await viewModel.switchAccount(id: account.id) }
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
                    Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("Configuration")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onBackClick) {
                    Image(systemName: "chevron.left")
                }
            }
        }
        .alert("Logout", isPresented: $showLogoutAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Logout", role: .destructive) {
                Task {
                    await viewModel.logout()
                    onLogout()
                }
            }
        } message: {
            Text("Are you sure you want to logout?")
        }
        .onAppear { viewModel.loadAccounts() }
    }
}
