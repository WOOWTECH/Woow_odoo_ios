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
        }
    }
}

/// Root view — login → auth gate → main screen.
/// Monitors scenePhase for bg→fg auth re-prompt (UX-20).
struct AppRootView: View {
    @StateObject private var authViewModel = AuthViewModel()
    @State private var isLoggedIn = false
    @State private var showPin = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !isLoggedIn {
                LoginView(onLoginSuccess: {
                    isLoggedIn = true
                    if !authViewModel.requiresAuth {
                        authViewModel.setAuthenticated(true)
                    }
                })
            } else if authViewModel.requiresAuth && !authViewModel.isAuthenticated {
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
                        // Will navigate to Config in M7
                    },
                    onSessionExpired: {
                        isLoggedIn = false
                        authViewModel.setAuthenticated(false)
                    }
                )
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                authViewModel.onAppBackgrounded()
                showPin = false
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
