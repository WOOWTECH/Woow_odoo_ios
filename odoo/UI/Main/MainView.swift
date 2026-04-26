import SwiftUI

/// Main screen — Odoo WebView with toolbar.
/// UX-25 through UX-34.
/// Ported from Android: MainScreen.kt
struct MainView: View {
    @StateObject private var viewModel = MainViewModel()
    let onMenuClick: () -> Void
    let onSessionExpired: () -> Void

    @State private var isLoading = true
    /// Controls the one-shot location-denied snackbar. Dismissed after the user taps
    /// "Open Settings" or the banner auto-hides. Posted by LocationCoordinator via
    /// Notification.Name.locationPermanentlyDenied.
    @State private var showLocationDeniedBanner = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
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

                if showLocationDeniedBanner {
                    LocationDeniedBanner {
                        showLocationDeniedBanner = false
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 16)
                    .padding(.horizontal, 16)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showLocationDeniedBanner)
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
        .onReceive(
            NotificationCenter.default.publisher(for: .locationPermanentlyDenied)
        ) { _ in
            withAnimation {
                showLocationDeniedBanner = true
            }
        }
    }
}

// MARK: - LocationDeniedBanner

/// One-shot snackbar shown when CLAuthorizationStatus is .denied.
/// iOS does not allow re-prompting, so the only recourse is to deep-link to Settings.
private struct LocationDeniedBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.slash")
                .foregroundStyle(.white)
            Text(String(localized: "location_denied_message"))
                .font(.footnote)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(String(localized: "location_open_settings")) {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
                onDismiss()
            }
            .font(.footnote.bold())
            .foregroundStyle(.white)
        }
        .padding(12)
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
