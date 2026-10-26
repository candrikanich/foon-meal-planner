import AuthenticationServices
import SwiftUI

struct WelcomeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Foon")
                .font(.largeTitle.bold())
            Text("Different tastes. Same table.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
            SignInWithAppleButton(.continue) { request in
                // Supabase Auth needs an email to create the account; Apple's private relay is fine.
                // It stays in Auth and is never copied into household data.
                request.requestedScopes = [.fullName, .email]
                request.nonce = session.appleRequestNonce()
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(maxWidth: 375)
            .frame(height: 50)
            if let message = session.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .onChange(of: session.errorMessage) { _, message in
            if let message {
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let idToken = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) })
            else {
                session.appleSignInFailed(cancelled: false)
                return
            }
            let givenName = credential.fullName?.givenName
            Task { await session.completeAppleSignIn(idToken: idToken, givenName: givenName) }
        case .failure(let error):
            session.appleSignInFailed(cancelled: (error as? ASAuthorizationError)?.code == .canceled)
        }
    }
}

#Preview {
    WelcomeView()
        .environment(SessionStore(auth: .preview()))
}
