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
            RootView()
        }
    }
}

/// Root content view — placeholder for M1.
/// Will be replaced with AppRouter + NavigationStack in M3/M4.
struct RootView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "building.2")
                .font(.system(size: 64))
                .foregroundStyle(WoowColors.primaryBlue)

            Text("WoowTech Odoo")
                .font(.title)
                .fontWeight(.bold)

            Text("iOS App — M1 Setup Complete")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    RootView()
}
