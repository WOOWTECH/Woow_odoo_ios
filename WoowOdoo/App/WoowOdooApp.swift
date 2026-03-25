import SwiftUI

/// Main entry point for the Woow Odoo iOS app.
/// Ported from Android: WoowOdooApp.kt + MainActivity.kt
@main
struct WoowOdooApp: App {

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Root content view — placeholder for M1.
/// Will be replaced with AppRouter + NavigationStack in M3/M4.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "building.2")
                .font(.system(size: 64))
                .foregroundStyle(WoowColors.primaryBlue)

            Text("WoowTech Odoo")
                .font(.title)
                .fontWeight(.bold)

            Text("iOS App — M1 Complete")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
