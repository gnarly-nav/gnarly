import CryptoKit
import Foundation
import Security

/// Hosted-UI helpers for the same Cognito Google IdP the website uses.
/// The user pool, app client, and domain are not modified here.
enum CognitoOAuth {
    static let defaultAPIBase = "https://m7sgp6qsjkimymyrwa6bilxqzq0acbhx.lambda-url.us-east-1.on.aws"
    static let defaultUserPoolID = "us-east-1_pQIUmVbPJ"
    static let defaultClientID = "1osnrt38iuqvf5laum1tnj1hdn"
    static let defaultDomain = "gnarly-naijei.auth.us-east-1.amazoncognito.com"
    static let defaultRedirectURI = "gnarlymapper://auth/"

    static func hostedHost(_ domain: String) -> String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func normalizeRedirect(_ uri: String) -> String {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func codeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func authorizeURL(domain: String, clientID: String, redirectURI: String, challenge: String, state: String, identityProvider: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = hostedHost(domain)
        components.path = "/oauth2/authorize"
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid email"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let identityProvider, !identityProvider.isEmpty {
            items.insert(URLQueryItem(name: "identity_provider", value: identityProvider), at: 0)
        }
        components.queryItems = items
        return components.url
    }

    static func tokenEndpoint(domain: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = hostedHost(domain)
        components.path = "/oauth2/token"
        return components.url
    }

    static func authorizationCodeBody(clientID: String, code: String, redirectURI: String, verifier: String) -> String {
        form([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", verifier),
        ])
    }

    static func refreshTokenBody(clientID: String, refreshToken: String) -> String {
        form([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", refreshToken),
        ])
    }

    struct Claims {
        var sub: String
        var email: String
        var emailVerified: Bool
        var exp: TimeInterval
    }

    static func idTokenClaims(_ idToken: String) throws -> Claims {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { throw CognitoAuthError("The Cognito ID token could not be read.") }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: payload),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CognitoAuthError("The Cognito ID token could not be read.")
        }
        let email = json["email"] as? String ?? ""
        let verified = json["email_verified"] as? Bool ?? ((json["email_verified"] as? String) == "true")
        let exp = json["exp"] as? TimeInterval ?? (json["exp"] as? NSNumber)?.doubleValue ?? 0
        return Claims(sub: json["sub"] as? String ?? "", email: email, emailVerified: verified, exp: exp)
    }

    /// Custom scheme for `ASWebAuthenticationSession(url:callbackURLScheme:)`.
    /// HTTPS redirects need an associated domain and are not used by this app.
    static func callbackScheme(redirectURI: String) -> String? {
        guard let scheme = URLComponents(string: redirectURI)?.scheme?.lowercased(),
              !scheme.isEmpty,
              scheme != "http",
              scheme != "https" else { return nil }
        return scheme
    }

    private static func form(_ pairs: [(String, String)]) -> String {
        pairs.map { key, value in
            "\(escape(key))=\(escape(value))"
        }.joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct CognitoAuthError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
