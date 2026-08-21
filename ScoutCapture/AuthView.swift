import Combine
import SwiftUI

enum PasswordRecoveryFlow {
    static let forgotPasswordButtonTitle = "Forgot Password?"
    nonisolated static let resetRedirectURL = URL(string: "https://scoutclear.com/reset-password")!
    static let successMessage = "Password reset email sent. Check your inbox for a link to choose a new password."
    static let successConfirmationTitle = "Password Reset Email Sent"

    static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isReasonablyEmailShaped(_ email: String) -> Bool {
        let trimmed = normalizedEmail(email)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }

        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty else {
            return false
        }

        let domainParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domainParts.count >= 2 && domainParts.allSatisfy { !$0.isEmpty }
    }
}

@MainActor
final class PasswordRecoveryFormModel: ObservableObject {
    @Published var email: String = ""
    @Published private(set) var isRequestInFlight = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var successMessage: String?

    var canSubmit: Bool {
        !isRequestInFlight && PasswordRecoveryFlow.isReasonablyEmailShaped(email)
    }

    func prepare(signInEmail: String) {
        email = PasswordRecoveryFlow.normalizedEmail(signInEmail)
        errorMessage = nil
        successMessage = nil
    }

    @discardableResult
    func submit(
        requestReset: @escaping (String, URL) async throws -> Void
    ) async -> Bool {
        guard !isRequestInFlight else { return false }

        let trimmedEmail = PasswordRecoveryFlow.normalizedEmail(email)
        guard PasswordRecoveryFlow.isReasonablyEmailShaped(trimmedEmail) else {
            errorMessage = "Enter a valid email address."
            successMessage = nil
            return false
        }

        isRequestInFlight = true
        errorMessage = nil
        successMessage = nil
        defer { isRequestInFlight = false }

        do {
            try await requestReset(trimmedEmail, PasswordRecoveryFlow.resetRedirectURL)
            successMessage = PasswordRecoveryFlow.successMessage
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

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
    @State private var passwordResetConfirmationMessage: String?
    @State private var isShowingForgotPassword = false
    @StateObject private var passwordRecovery = PasswordRecoveryFormModel()

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

                VStack {
                    if let passwordResetConfirmationMessage, !passwordResetConfirmationMessage.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20, weight: .semibold))

                            Text(passwordResetConfirmationMessage)
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(Color(uiColor: .systemBackground))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.green.opacity(0.45), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 6)
                        .padding(.horizontal, 20)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, proxy.safeAreaInsets.top + 12)
                .zIndex(1)

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

                            if mode == .signIn {
                                Button(PasswordRecoveryFlow.forgotPasswordButtonTitle) {
                                    infoMessage = nil
                                    passwordResetConfirmationMessage = nil
                                    passwordRecovery.prepare(signInEmail: emailTrimmed)
                                    isShowingForgotPassword = true
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.blue)
                                .disabled(appState.isAuthenticating || passwordRecovery.isRequestInFlight)
                            }
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
                        passwordResetConfirmationMessage = nil
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $isShowingForgotPassword) {
            PasswordRecoverySheet(
                model: passwordRecovery,
                onCancel: {
                    isShowingForgotPassword = false
                },
                onSubmit: { dismissKeyboard in
                    Task {
                        let didSend = await passwordRecovery.submit { email, redirectURL in
                            try await appState.requestPasswordReset(email: email, redirectTo: redirectURL)
                        }
                        if didSend {
                            dismissKeyboard()
                            passwordResetConfirmationMessage = PasswordRecoveryFlow.successConfirmationTitle
                            isShowingForgotPassword = false
                        }
                    }
                }
            )
            .presentationDetents([.medium])
        }
    }

    private var emailTrimmed: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        infoMessage = nil
        passwordResetConfirmationMessage = nil

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

private struct PasswordRecoverySheet: View {
    @ObservedObject var model: PasswordRecoveryFormModel
    let onCancel: () -> Void
    let onSubmit: (@escaping () -> Void) -> Void
    @FocusState private var isEmailFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                TextField("Account email", text: $model.email)
                    .focused($isEmailFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(model.isRequestInFlight)

                if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    onSubmit {
                        isEmailFieldFocused = false
                    }
                } label: {
                    if model.isRequestInFlight {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 50)
                    } else {
                        Text("Send Reset Email")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(!model.canSubmit)
                .opacity(model.canSubmit ? 1.0 : 0.6)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Reset Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(model.isRequestInFlight)
                }
            }
        }
    }
}
