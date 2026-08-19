import SwiftUI

struct AuthView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case signIn
        case signUp

        var id: String { rawValue }

        var title: String {
            switch self {
            case .signIn:
                return "Sign In"
            case .signUp:
                return "Create Account"
            }
        }

        var buttonTitle: String {
            switch self {
            case .signIn:
                return "Sign In"
            case .signUp:
                return "Create Account"
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @State private var mode: Mode = .signIn
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var infoMessage: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color.black,
                        Color.blue
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        Spacer(minLength: 0)

                        VStack(spacing: 12) {
                            Image("ScoutCaptureLogoWhite")
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220)

                            Text("Supabase authentication is required to access organization-scoped data.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }

                        VStack(spacing: 16) {
                            Picker("Authentication Mode", selection: $mode) {
                                ForEach(Mode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            VStack(spacing: 12) {
                                TextField("Email", text: $email)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.emailAddress)
                                    .textContentType(.emailAddress)
                                    .padding(.horizontal, 14)
                                    .frame(height: 50)
                                    .background(Color(uiColor: .secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                SecureField("Password", text: $password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .textContentType(mode == .signIn ? .password : .newPassword)
                                    .padding(.horizontal, 14)
                                    .frame(height: 50)
                                    .background(Color(uiColor: .secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }

                            if let infoMessage, !infoMessage.isEmpty {
                                Text(infoMessage)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }

                            if let authenticationErrorMessage = appState.authenticationErrorMessage,
                               !authenticationErrorMessage.isEmpty {
                                Text(authenticationErrorMessage)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                            }

                            Button(action: submit) {
                                if appState.isAuthenticating {
                                    ProgressView()
                                        .tint(.white)
                                        .frame(maxWidth: .infinity, minHeight: 50)
                                } else {
                                    Text(mode.buttonTitle)
                                        .font(.system(size: 17, weight: .semibold))
                                        .frame(maxWidth: .infinity, minHeight: 50)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .background(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .disabled(appState.isAuthenticating || emailTrimmed.isEmpty || password.isEmpty)
                            .opacity(appState.isAuthenticating || emailTrimmed.isEmpty || password.isEmpty ? 0.6 : 1.0)
                        }
                        .padding(20)
                        .background(Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .padding(.horizontal, 20)

                        Spacer(minLength: 8)
                    }
                    .padding(.vertical, 24)
                    .padding(.bottom, 145)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .bottom)
                    .onChange(of: mode) { _, _ in
                        infoMessage = nil
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .ignoresSafeArea()
    }

    private var emailTrimmed: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        infoMessage = nil

        Task {
            switch mode {
            case .signIn:
                try? await appState.signIn(email: emailTrimmed, password: password)
            case .signUp:
                if let result = try? await appState.signUp(email: emailTrimmed, password: password),
                   result == .requiresEmailConfirmation {
                    await MainActor.run {
                        infoMessage = "Account created. If your project requires confirmation, approve the email and then sign in."
                    }
                }
            }
        }
    }
}
