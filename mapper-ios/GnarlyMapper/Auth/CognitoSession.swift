import AuthenticationServices
import Foundation
import Security
import UIKit

/// Cognito session for the mapper. Google and email both use the hosted UI with PKCE,
/// the same public app client as the website, and the ID token on publish API calls.
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
    func signInWithEmail() async -> Bool {
        await signIn(identityProvider: nil)
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        webSession?.cancel()
        webSession = nil
        tokens = nil
        CognitoKeychain.clear()
        userUID = nil
        email = nil
        emailVerified = false
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
        do { _ = try await requireIdToken() }
        catch {
            signOut()
        }
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
        } catch {
            signOut()
            throw PackagePublishError("Sign in again.")
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
