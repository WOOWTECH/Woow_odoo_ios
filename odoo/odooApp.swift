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
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "woowodoo" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return
        }
        if DeepLinkValidator.isValid(url: urlParam, serverHost: "") {
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch rootViewModel.launchState {
            case .loading:
                ProgressView()
            case .login:
                LoginView(onLoginSuccess: {
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
                    .sheet(isPresented: $showConfig) {
                        ConfigView(
                            onBackClick: {
                                showConfig = false
                            },
                            onSettingsClick: {
                                // Navigation handled inside ConfigView's NavigationStack
                            },
                            onAddAccountClick: {
                                showConfig = false
                                rootViewModel.onSessionExpired()
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
