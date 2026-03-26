//
//  odooApp.swift
//  odoo
//
//  Created by Alan Lin on 2026/3/26.
//

import SwiftUI

@main
struct odooApp: App {

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

/// Root view — login or main screen.
/// Auth gate (biometric/PIN) will be added in M4.
struct AppRootView: View {
    @State private var isLoggedIn = false

    var body: some View {
        if isLoggedIn {
            MainPlaceholderView(onLogout: { isLoggedIn = false })
        } else {
            LoginView(onLoginSuccess: { isLoggedIn = true })
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
