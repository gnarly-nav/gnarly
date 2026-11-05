import AuthenticationServices
import Foundation
import Security
import UIKit

/// Cognito session for the mapper. Google uses the hosted UI with PKCE.
/// Email and password use the same USER_SRP_AUTH challenge as the website.
/// API calls send the ID token. This app does not create accounts.
@MainActor
final class CognitoSession: ObservableObject {
    static let shared = CognitoSession()

    @Published private(set) var userUID: String?
    @Published private(set) var email: String?
    @Published private(set) var emailVerified = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    var isAuthenticated: Bool { userUID != nil }

    private var tokens: StoredTokens?
    private var refreshTask: Task<String, Error>?
    private var webSession: ASWebAuthenticationSession?
    private let presenter = WebAuthPresenter()

    private init() {
        if let stored = CognitoKeychain.load() {
            tokens = stored
            apply(stored.idToken)
            Task { await refreshIfStale() }
        }
    }

    func clearError() { errorMessage = nil }

    @discardableResult
    func signInWithGoogle() async -> Bool {
        await signIn(identityProvider: "Google")
    }

    @discardableResult
    func signInWithEmail(_ emailAddress: String, password: String) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let username = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Enter the email and password for this Cognito account."
            return false
        }
        do {
            try await runPasswordSignIn(username: username, password: password)
            return true
        } catch let error as CognitoAuthError {
            errorMessage = error.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        webSession?.cancel()
        webSession = nil
        clearSession()
        errorMessage = nil
    }

    /// Cognito ID token for the publish API. Access tokens have no email claim.
    func requireIdToken() async throws -> String {
        if let token = freshIDToken() { return token }
        guard tokens?.refreshToken.isEmpty == false else {
            throw PackagePublishError("Sign in before changing buildings.")
        }
        if refreshTask == nil {
            refreshTask = Task { try await self.refresh() }
        }
        let task = refreshTask!
        do {
            let token = try await task.value
            if refreshTask == task { refreshTask = nil }
            return token
        } catch {
            if refreshTask == task { refreshTask = nil }
            throw error
        }
    }

    private func signIn(identityProvider: String?) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            if #available(iOS 17.4, *) {
                try await runHostedSignIn(identityProvider: identityProvider)
                return true
            }
            throw CognitoAuthError("Sign in needs iOS 17.4 or later so the app can use the website’s Cognito redirect.")
        } catch let error as CognitoAuthError {
            errorMessage = error.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @available(iOS 17.4, *)
    private func runHostedSignIn(identityProvider: String?) async throws {
        let config = GnarlyAwsConfig.current
        let verifier = CognitoOAuth.codeVerifier()
        let state = CognitoOAuth.codeVerifier()
        let challenge = CognitoOAuth.codeChallenge(verifier)
        guard let url = CognitoOAuth.authorizeURL(
            domain: config.domain,
            clientID: config.clientID,
            redirectURI: config.redirectURI,
            challenge: challenge,
            state: state,
            identityProvider: identityProvider
        ) else { throw CognitoAuthError("The Cognito sign-in URL is invalid.") }
        guard let callback = CognitoOAuth.callbackParts(redirectURI: config.redirectURI) else {
            throw CognitoAuthError("The Cognito redirect URL is invalid.")
        }
        let returned = try await present(url: url, host: callback.host, path: callback.path)
        guard let components = URLComponents(url: returned, resolvingAgainstBaseURL: false) else {
            throw CognitoAuthError("Google sign-in could not be completed. Try again.")
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        if let oauthError = query["error_description"] ?? query["error"], !oauthError.isEmpty {
            throw CognitoAuthError(oauthError)
        }
        guard query["state"] == state, let code = query["code"], !code.isEmpty else {
            throw CognitoAuthError("Google sign-in could not be completed. Try again.")
        }
        let body = CognitoOAuth.authorizationCodeBody(
            clientID: config.clientID,
            code: code,
            redirectURI: config.redirectURI,
            verifier: verifier
        )
        let next = try await requestTokens(body: body, fallbackRefresh: nil)
        store(next)
    }

    private func refreshIfStale() async {
        guard tokens != nil, freshIDToken() == nil else { return }
        // A rejected refresh token clears the session inside refresh(). A network failure leaves it for the next try.
        try? await requireIdToken()
    }

    private func freshIDToken() -> String? {
        guard let tokens, tokens.expiresAt > Date().addingTimeInterval(60) else { return nil }
        apply(tokens.idToken)
        return tokens.idToken
    }

    private func refresh() async throws -> String {
        guard let tokens, !tokens.refreshToken.isEmpty else {
            throw PackagePublishError("Sign in before changing buildings.")
        }
        let config = GnarlyAwsConfig.current
        let body = CognitoOAuth.refreshTokenBody(clientID: config.clientID, refreshToken: tokens.refreshToken)
        do {
            let next = try await requestTokens(body: body, fallbackRefresh: tokens.refreshToken)
            store(next)
            return next.idToken
        } catch is CognitoAuthError {
            clearSession()
            throw PackagePublishError("Sign in again.")
        } catch {
            throw PackagePublishError("The Cognito session could not be refreshed. Check the connection and try again.")
        }
    }

    private func clearSession() {
        tokens = nil
        CognitoKeychain.clear()
        userUID = nil
        email = nil
        emailVerified = false
    }

    private func runPasswordSignIn(username: String, password: String) async throws {
        let config = GnarlyAwsConfig.current
        guard let poolName = CognitoSrp.poolName(config.userPoolID),
              let region = CognitoSrp.region(config.userPoolID),
              let endpoint = URL(string: "https://cognito-idp.\(region).amazonaws.com/") else {
            throw CognitoAuthError("The Cognito user pool id is invalid.")
        }
        let secret = try CognitoSrp.randomSecret()
        let srpA = try CognitoSrp.publicValue(secretHex: secret)
        let started = try await cognitoCall(endpoint, target: "InitiateAuth", body: [
            "AuthFlow": "USER_SRP_AUTH",
            "ClientId": config.clientID,
            "AuthParameters": ["USERNAME": username, "SRP_A": srpA],
        ])
        if let challenge = started["ChallengeName"] as? String, challenge != "PASSWORD_VERIFIER" {
            throw CognitoAuthError(Self.challengeMessage(challenge))
        }
        guard let parameters = started["ChallengeParameters"] as? [String: Any],
              let user = parameters["USER_ID_FOR_SRP"] as? String, !user.isEmpty,
              let serverB = parameters["SRP_B"] as? String, !serverB.isEmpty,
              let salt = parameters["SALT"] as? String, !salt.isEmpty,
              let block = parameters["SECRET_BLOCK"] as? String, !block.isEmpty else {
            throw CognitoAuthError("Cognito did not return a password challenge.")
        }
        let key = try CognitoSrp.authenticationKey(
            poolName: poolName,
            username: user,
            password: password,
            secretHex: secret,
            srpBHex: serverB,
            saltHex: salt
        )
        let stamp = CognitoSrp.timestamp()
        let signature = try CognitoSrp.claimSignature(
            key: key, poolName: poolName, username: user, secretBlock: block, timestamp: stamp
        )
        var body: [String: Any] = [
            "ChallengeName": "PASSWORD_VERIFIER",
            "ClientId": config.clientID,
            "ChallengeResponses": [
                "USERNAME": user,
                "PASSWORD_CLAIM_SECRET_BLOCK": block,
                "TIMESTAMP": stamp,
                "PASSWORD_CLAIM_SIGNATURE": signature,
            ],
        ]
        if let session = started["Session"] as? String, !session.isEmpty { body["Session"] = session }
        let finished = try await cognitoCall(endpoint, target: "RespondToAuthChallenge", body: body)
        if let challenge = finished["ChallengeName"] as? String, !challenge.isEmpty {
            throw CognitoAuthError(Self.challengeMessage(challenge))
        }
        guard let result = finished["AuthenticationResult"] as? [String: Any],
              let idToken = result["IdToken"] as? String, !idToken.isEmpty,
              let accessToken = result["AccessToken"] as? String, !accessToken.isEmpty else {
            throw CognitoAuthError("Cognito did not return tokens.")
        }
        let refresh = (result["RefreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ""
        let expiresIn = (result["ExpiresIn"] as? NSNumber)?.doubleValue ?? (result["ExpiresIn"] as? Double) ?? 3600
        store(StoredTokens(
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        ))
    }

    private func cognitoCall(_ endpoint: URL, target: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.\(target)", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (json["message"] as? String) ?? (json["__type"] as? String) ?? "Cognito rejected the password sign-in."
            throw CognitoAuthError(message)
        }
        return json
    }

    private static func challengeMessage(_ name: String) -> String {
        switch name {
        case "NEW_PASSWORD_REQUIRED":
            return "This account still has a temporary Cognito password. Set a permanent password in the user pool, then sign in again. This app does not create users."
        case "SMS_MFA", "SOFTWARE_TOKEN_MFA":
            return "This account requires MFA, which this form does not complete."
        default:
            return "Cognito asked for \(name), which this form does not complete."
        }
    }

    private func requestTokens(body: String, fallbackRefresh: String?) async throws -> StoredTokens {
        let config = GnarlyAwsConfig.current
        guard let endpoint = CognitoOAuth.tokenEndpoint(domain: config.domain) else {
            throw CognitoAuthError("The Cognito token URL is invalid.")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let idToken = json["id_token"] as? String ?? ""
        let accessToken = json["access_token"] as? String ?? ""
        guard (200..<300).contains(status), !idToken.isEmpty, !accessToken.isEmpty else {
            let message = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "Cognito did not return tokens."
            throw CognitoAuthError(message)
        }
        let refresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackRefresh ?? ""
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? (json["expires_in"] as? Double) ?? 3600
        return StoredTokens(
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private func store(_ next: StoredTokens) {
        tokens = next
        CognitoKeychain.save(next)
        apply(next.idToken)
    }

    private func apply(_ idToken: String) {
        guard let claims = try? CognitoOAuth.idTokenClaims(idToken) else { return }
        userUID = claims.sub
        email = claims.email
        emailVerified = claims.emailVerified
    }

    @available(iOS 17.4, *)
    private func present(url: URL, host: String, path: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeOnce(continuation)
            let session = ASWebAuthenticationSession(url: url, callback: .https(host: host, path: path)) { callbackURL, error in
                if let callbackURL {
                    gate.resume(returning: callbackURL)
                    return
                }
                let ns = error as NSError?
                if ns?.domain == ASWebAuthenticationSessionError.errorDomain,
                   ns?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    gate.resume(throwing: CognitoAuthError("Sign-in was canceled."))
                } else {
                    gate.resume(throwing: CognitoAuthError(error?.localizedDescription ?? "Sign-in failed."))
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                gate.resume(throwing: CognitoAuthError("Could not open the sign-in page."))
            }
        }
    }
}

struct GnarlyAwsConfig {
    var apiBase: URL
    var userPoolID: String
    var clientID: String
    var domain: String
    var redirectURI: String

    static var current: GnarlyAwsConfig {
        let bundle = Bundle.main
        func string(_ key: String, fallback: String) -> String {
            let raw = (bundle.object(forInfoDictionaryKey: key) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? fallback : raw
        }
        let apiRaw = string("GnarlyApiBaseURL", fallback: CognitoOAuth.defaultAPIBase)
        let api = (try? GnarlyApiConfig.url(from: apiRaw)) ?? URL(string: CognitoOAuth.defaultAPIBase)!
        return GnarlyAwsConfig(
            apiBase: api,
            userPoolID: string("CognitoUserPoolId", fallback: CognitoOAuth.defaultUserPoolID),
            clientID: string("CognitoClientId", fallback: CognitoOAuth.defaultClientID),
            domain: string("CognitoDomain", fallback: CognitoOAuth.defaultDomain),
            redirectURI: CognitoOAuth.normalizeRedirect(string("CognitoRedirectURI", fallback: CognitoOAuth.defaultRedirectURI))
        )
    }
}

private struct StoredTokens: Codable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

private enum CognitoKeychain {
    static let service = "com.grantlin.gnarly.mapper.cognito"
    static let account = "tokens"

    static func save(_ tokens: StoredTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> StoredTokens? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    static func clear() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: URL) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}
