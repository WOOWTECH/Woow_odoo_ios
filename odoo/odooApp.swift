//
//  odooApp.swift
//  odoo
//
//  Created by Alan Lin on 2026/3/26.
//

import SwiftUI

@main
struct odooApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }

    /// Routes incoming `woowodoo://` URLs through validation and into DeepLinkManager.
    /// Expected format: `woowodoo://open?url=/web%23id=42`
    ///
    /// Reads the active account's server host to validate absolute URLs against the
    /// user's actual server. Relative `/web` paths are validated against the strict
    /// path regex inside `DeepLinkValidator.isValid`.
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "woowodoo" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return
        }
        let serverHost = AccountRepository().getActiveAccount()?.serverHost ?? ""
        if DeepLinkValidator.isValid(url: urlParam, serverHost: serverHost) {
            DeepLinkManager.shared.setPending(urlParam)
        }
    }
}

/// Root view — login → auth gate → main screen.
/// Uses `AppRootViewModel` to check for an existing active account on launch,
/// enabling auto-login when credentials are already saved (Core Data + Keychain).
/// Monitors scenePhase for bg→fg auth re-prompt (UX-20).
struct AppRootView: View {
    @StateObject private var rootViewModel = AppRootViewModel()
    @StateObject private var authViewModel = AuthViewModel()
    @ObservedObject private var theme = WoowTheme.shared
    @State private var showPin = false
    @State private var showConfig = false
    @State private var showPrivacyOverlay = false
    /// Set to true when the user taps "Add Account" so that after the Config sheet
    /// finishes its dismissal animation, the app transitions to the login screen.
    /// Combining sheet dismissal with a parent-view swap in the same state update
    /// prevents SwiftUI from completing the sheet animation, so the transition is
    /// deferred to the sheet's onDismiss callback.
    @State private var pendingAddAccount = false
    /// Tracks whether the login screen was reached via "Add Account" so that
    /// LoginView can start at the server info step instead of pre-filling the
    /// existing active account's credentials.
    @State private var isAddingAccount = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch rootViewModel.launchState {
            case .loading:
                ProgressView()
            case .login:
                LoginView(addingAccount: isAddingAccount, onLoginSuccess: {
                    isAddingAccount = false
                    rootViewModel.onLoginSuccess()
                    if !authViewModel.requiresAuth {
                        authViewModel.setAuthenticated(true)
                    }
                })
            case .authenticated:
                if authViewModel.requiresAuth && !authViewModel.isAuthenticated {
                    if showPin {
                        PinView(
                            authViewModel: authViewModel,
                            onPinVerified: { showPin = false },
                            onBackClick: { showPin = false }
                        )
                    } else {
                        BiometricView(
                            authViewModel: authViewModel,
                            onAuthSuccess: {},
                            onUsePinClick: { showPin = true }
                        )
                    }
                } else {
                    MainView(
                        onMenuClick: {
                            showConfig = true
                        },
                        onSessionExpired: {
                            rootViewModel.onSessionExpired()
                            authViewModel.setAuthenticated(false)
                        }
                    )
                    .sheet(isPresented: $showConfig, onDismiss: {
                        // Deferred transition: navigate to login only after the sheet
                        // dismissal animation completes. Changing launchState while the
                        // sheet is still animating out causes SwiftUI to drop the
                        // transition, leaving the login screen unreachable.
                        if pendingAddAccount {
                            pendingAddAccount = false
                            isAddingAccount = true
                            rootViewModel.onSessionExpired()
                        }
                    }) {
                        ConfigView(
                            onBackClick: {
                                showConfig = false
                            },
                            onSettingsClick: {
                                // Navigation handled inside ConfigView's NavigationStack
                            },
                            onAddAccountClick: {
                                // Mark the intent and dismiss the sheet. The actual
                                // launchState transition happens in onDismiss after
                                // the sheet animation completes.
                                pendingAddAccount = true
                                showConfig = false
                            },
                            onLogout: {
                                showConfig = false
                                rootViewModel.onSessionExpired()
                                authViewModel.setAuthenticated(false)
                            }
                        )
                    }
                }
            }
        }
        // Disable cross-fade transition when switching between launch states.
        // SwiftUI's default Group transition keeps both the outgoing and incoming
        // views in the accessibility hierarchy simultaneously, so an XCUITest
        // asserting the WebView is gone would see it while it fades out. Using
        // .identity means the swap is instantaneous — no overlap in the tree.
        .transaction { $0.animation = nil }
        .preferredColorScheme(theme.colorSchemeOverride)
        .overlay {
            // H4: Privacy overlay — hides sensitive content in task switcher
            if showPrivacyOverlay {
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .overlay {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task {
            rootViewModel.checkSession()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background, .inactive:
                if rootViewModel.launchState == .authenticated {
                    authViewModel.onAppBackgrounded()
                    showPin = false
                    showPrivacyOverlay = true  // H4: hide content in task switcher
                }
            case .active:
                showPrivacyOverlay = false
            @unknown default:
                break
            }
        }
    }
}

/// Placeholder for main screen — replaced by WKWebView in M5.
struct MainPlaceholderView: View {
    let onLogout: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Login Successful")
                .font(.title).fontWeight(.bold)
            Text("WKWebView will be here in M5")
                .foregroundStyle(.secondary)
            Button("Logout", role: .destructive) { onLogout() }
                .padding(.top, 20)
        }
    }
}

#Preview("Login") { LoginView(onLoginSuccess: {}) }
#Preview("Main") { MainPlaceholderView(onLogout: {}) }
