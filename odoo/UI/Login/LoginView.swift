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
    /// Non-nil only for "Add Account" in front of a signed-in account: shows a Cancel button that
    /// returns to that account.
    let onCancel: (() -> Void)?

    @StateObject private var viewModel: LoginViewModel
    /// Observes the user's theme color so the logo accent + button tints

    init(addingAccount: Bool = false, signInAccount: OdooAccount? = nil,
         onLoginSuccess: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        self.addingAccount = addingAccount
        self.onLoginSuccess = onLoginSuccess
        self.onCancel = onCancel
        _viewModel = StateObject(wrappedValue: LoginViewModel(addingAccount: addingAccount, signInAccount: signInAccount))
    }

    @FocusState private var focusedField: LoginViewModel.Field?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        // Logo
                        Image(AppBrand.current.logoAsset)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                            .padding(.top, 40)

                        Text(AppBrand.current.displayName)
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
                // Return behaves like the step's action button (same validation), or moves on.
                .onSubmit {
                    guard let field = focusedField else { return }
                    focusedField = viewModel.handleReturnKey(in: field, onLoginSuccess: onLoginSuccess)
                }
                // Keep the action button above the keyboard. Re-run on keyboardDidShow because the
                // ScrollView only gains its keyboard inset once the keyboard is on screen.
                .onChange(of: focusedField) { field in
                    revealActionButton(for: field, with: proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    revealActionButton(for: focusedField, with: proxy)
                }
            }
            .navigationBarHidden(true)
            .overlay(alignment: .topLeading) {
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .accessibilityIdentifier("login.cancelAddAccount")
                }
            }
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

    private func revealActionButton(for field: LoginViewModel.Field?, with proxy: ScrollViewProxy) {
        guard let field else { return }
        withAnimation {
            proxy.scrollTo(LoginViewModel.actionButton(revealedFor: field), anchor: .bottom)
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
                    // Hidden once the text has its own scheme, so "http://…" never reads as
                    // "https://http://…" (Android W2-4 U4). Validation is unchanged.
                    if ServerUrlInput.showsFixedSchemePrefix(for: viewModel.serverUrl) {
                        Text("https://")
                            .foregroundStyle(.secondary)
                    }
                    TextField("example.odoo.com", text: $viewModel.serverUrl)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($focusedField, equals: .serverUrl)
                        .submitLabel(.next)
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
                    .submitLabel(.next)
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
            .tint(WoowTheme.fixedBrandColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .id(LoginViewModel.ActionButton.next)
        }
    }

    // MARK: - Step 2: Credentials

    private var credentialFields: some View {
        VStack(spacing: 16) {
            // Show server info summary
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(WoowTheme.fixedBrandColor)
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
                    .submitLabel(.next)
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
                    .submitLabel(.go)
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
            .tint(WoowTheme.fixedBrandColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .id(LoginViewModel.ActionButton.login)

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
