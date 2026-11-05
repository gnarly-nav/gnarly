import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var auth: CognitoSession
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Use the same Cognito account as the website. Google is the primary sign-in. This app does not create accounts.")
                        .font(.subheadline)
                        .foregroundStyle(MapperTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = auth.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Error. \(error)")
                }

                MapperPrimaryButton(
                    title: "Sign in with Google",
                    systemImage: "person.crop.circle",
                    busy: auth.isWorking,
                    enabled: !auth.isWorking
                ) {
                    Task { _ = await auth.signInWithGoogle() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Email")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MapperTheme.muted)
                    TextField("name@school.edu", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .font(.body)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(MapperTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                    Text("Password")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MapperTheme.muted)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .font(.body)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(MapperTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .disabled(auth.isWorking)

                Button {
                    Task { _ = await auth.signInWithEmail(email, password: password) }
                } label: {
                    Text("Sign in with email")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MapperTheme.accent)
                .disabled(auth.isWorking || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)

                Text("Anyone signed in can browse maps. Only the authorized editor account can publish or move a building.")
                    .font(.footnote)
                    .foregroundStyle(MapperTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MapperTheme.background.ignoresSafeArea())
    }
}
