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
    /// Non-nil while a "Switched to <account>" landing toast is shown after a multi-account logout
    /// promoted a remaining account. Auto-clears after a few seconds.
    @State private var fallbackToastAccount: String?
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
                authenticatedContent
            }
        }
        // Disable cross-fade transition when switching between launch states.
        // SwiftUI's default Group transition keeps both the outgoing and incoming
        // views in the accessibility hierarchy simultaneously, so an XCUITest
        // asserting the WebView is gone would see it while it fades out. Using
        // .identity means the swap is instantaneous — no overlap in the tree.
        .transaction { $0.animation = nil }
        .preferredColorScheme(theme.colorSchemeOverride)
        .overlay(alignment: .top) {
            // Landing toast after a multi-account logout promoted a remaining account, so the user
            // knows WHICH account they're now in (the WebView content changes underneath them).
            if let account = fallbackToastAccount {
                let switchedMessage = String(format: String(localized: "account_switched_to"), account)
                Text(switchedMessage)
                    .font(.subheadline).fontWeight(.medium)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: account) {
                        UIAccessibility.post(notification: .announcement, argument: switchedMessage)
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        fallbackToastAccount = nil
                    }
            }
        }
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
            guard rootViewModel.launchState == .authenticated else { return }
            switch newPhase {
            case .inactive:
                // H4: iOS snapshots for the task switcher at .inactive — cover sensitive content.
                // Do NOT re-lock here: the Face ID sheet itself drives the app .inactive.
                showPrivacyOverlay = true
            case .background:
                // True background → re-lock (VM resets the loop guard + bumps the stale-success token).
                authViewModel.appDidEnterBackground()
                showPrivacyOverlay = true
            case .active:
                showPrivacyOverlay = false
                // Auto-run the biometric prompt once per lock — seamless single-method unlock.
                authViewModel.appDidBecomeActive()
            @unknown default:
                break
            }
        }
        .onChange(of: rootViewModel.launchState) { newState in
            // Cold launch / post-login: drive the auto-prompt when the gate is first reached.
            if newState == .authenticated {
                authViewModel.appDidBecomeActive()
            }
        }
        .onChange(of: authViewModel.isAuthenticated) { authed in
            // Reset the Config sheet on re-lock so it is not re-presented after re-auth.
            if !authed { showConfig = false }
        }
    }

    // MARK: - Authenticated content (extracted so the `body` type-checks quickly)

    /// Renders the App Lock gate purely from `authViewModel.uiState`. No auth control-flow here.
    @ViewBuilder
    private var authenticatedContent: some View {
        switch authViewModel.uiState {
        case .unlocked:
            mainContent
        case .biometric(let prompting, let error, let kind, let showUsePin):
            BiometricView(
                kind: kind,
                prompting: prompting,
                error: error,
                showUsePin: showUsePin,
                onRetry: { authViewModel.retryBiometric() },
                onUsePin: { authViewModel.usePin() }
            )
        case .pin(let showBack):
            PinView(
                authViewModel: authViewModel,
                onPinVerified: {},
                onBackClick: { authViewModel.backFromPin() },
                showBack: showBack
            )
        case .setupRequired(let prompting, let error):
            AuthSetupRequiredView(
                prompting: prompting,
                error: error,
                onUnlock: { authViewModel.unlockWithDevicePasscode() }
            )
        }
    }

    /// The unlocked main screen + the Config sheet / add-account / logout orchestration (kept in the
    /// View — the ViewModel owns only lock-vs-content selection).
    private var mainContent: some View {
        MainView(
            onMenuClick: { showConfig = true },
            onSessionExpired: {
                rootViewModel.onSessionExpired()
                authViewModel.setAuthenticated(false)
            }
        )
        .sheet(isPresented: $showConfig, onDismiss: {
            // Deferred transition: navigate to login only after the sheet dismissal animation.
            if pendingAddAccount {
                pendingAddAccount = false
                isAddingAccount = true
                rootViewModel.onSessionExpired()
            }
        }) {
            ConfigView(
                onBackClick: { showConfig = false },
                onSettingsClick: {
                    // Navigation handled inside ConfigView's NavigationStack
                },
                onAddAccountClick: {
                    pendingAddAccount = true
                    showConfig = false
                },
                onLogout: { stayAuthenticated in
                    showConfig = false
                    if stayAuthenticated {
                        // Multi-account fallback: another account was promoted — landing toast.
                        fallbackToastAccount = AccountRepository().getActiveAccount()?.displayName
                    } else {
                        // Last account logged out — return to the login screen.
                        rootViewModel.onSessionExpired()
                        authViewModel.setAuthenticated(false)
                    }
                }
            )
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
