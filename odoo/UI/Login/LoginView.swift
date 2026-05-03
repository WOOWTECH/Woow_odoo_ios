import SwiftUI

/// Two-step login screen — Server Info → Credentials.
/// Ported from Android: LoginScreen.kt
/// UX-01 through UX-09 from functional equivalence matrix.
struct LoginView: View {
    /// When true, the server info step is always shown so the user can configure a
    /// new account from scratch rather than landing on the credentials step pre-filled
    /// with the existing active account's details.
    let addingAccount: Bool
    let onLoginSuccess: () -> Void

    @StateObject private var viewModel: LoginViewModel
    /// Observes the user's theme color so the logo accent + button tints
    /// reflect the current theme (UX-48). See `WoowTheme.swift`.
    @ObservedObject private var theme = WoowTheme.shared

    init(addingAccount: Bool = false, onLoginSuccess: @escaping () -> Void) {
        self.addingAccount = addingAccount
        self.onLoginSuccess = onLoginSuccess
        _viewModel = StateObject(wrappedValue: LoginViewModel(addingAccount: addingAccount))
    }

    @FocusState private var focusedField: Field?
    enum Field { case serverUrl, database, username, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Logo
                    Image(systemName: "building.2")
                        .font(.system(size: 56))
                        .foregroundStyle(theme.primaryColor)
                        .padding(.top, 40)

                    Text("WoowTech Odoo")
                        .font(.title)
                        .fontWeight(.bold)

                    Text(viewModel.step == .serverInfo ? String(localized: "Enter server details") : String(localized: "Enter credentials"))
                        .foregroundStyle(.secondary)

                    // Error banner
                    if let error = viewModel.error {
                        ErrorBannerView(message: error)
                    }

                    // Step content
                    if viewModel.step == .serverInfo {
                        serverInfoFields
                    } else {
                        credentialFields
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 500) // iPad: limit width
            }
            .navigationBarHidden(true)
            .disabled(viewModel.isLoading)
            .overlay {
                if viewModel.isLoading {
                    ProgressView("Connecting...")
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Step 1: Server Info

    private var serverInfoFields: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("https://")
                        .foregroundStyle(.secondary)
                    TextField("example.odoo.com", text: $viewModel.serverUrl)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($focusedField, equals: .serverUrl)
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Database")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Enter database name", text: $viewModel.database)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .database)
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button(action: viewModel.goToNextStep) {
                Text("Next")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primaryColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Step 2: Credentials

    private var credentialFields: some View {
        VStack(spacing: 16) {
            // Show server info summary
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(theme.primaryColor)
                VStack(alignment: .leading) {
                    Text(viewModel.displayUrl)
                        .font(.caption)
                    Text(viewModel.database)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change") {
                    viewModel.goBack()
                }
                .font(.caption)
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                Text("Username")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Username or email", text: $viewModel.username)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .focused($focusedField, equals: .username)
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SecureField("Enter password", text: $viewModel.password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button {
                viewModel.login(onSuccess: onLoginSuccess)
            } label: {
                Text("Login")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primaryColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button("Back") {
                viewModel.goBack()
            }
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    LoginView(onLoginSuccess: {})
}
