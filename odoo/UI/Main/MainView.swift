import SwiftUI

/// Main screen — Odoo WebView with toolbar.
/// UX-25 through UX-34.
/// Ported from Android: MainScreen.kt
struct MainView: View {
    @StateObject private var viewModel = MainViewModel()
    let onMenuClick: () -> Void
    let onSessionExpired: () -> Void

    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack {
                if let account = viewModel.activeAccount {
                    OdooWebView(
                        serverUrl: account.fullServerUrl,
                        database: account.database,
                        sessionId: viewModel.sessionId,
                        deepLinkUrl: viewModel.consumePendingDeepLink(),
                        onSessionExpired: onSessionExpired,
                        isLoading: $isLoading
                    )
                    .ignoresSafeArea(edges: .bottom)
                }

                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("WoowTech Odoo")
                        .font(.headline)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: onMenuClick) {
                        Image(systemName: "line.3.horizontal")
                    }
                }
            }
            .toolbarBackground(WoowColors.primaryBlue, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear {
            viewModel.loadActiveAccount()
        }
    }
}
