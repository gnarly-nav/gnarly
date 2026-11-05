import XCTest
@testable import GnarlyMapper

final class CognitoOAuthTests: XCTestCase {
    func testGoogleAuthorizeURLMatchesTheWebsitePKCEFlow() throws {
        let url = try XCTUnwrap(CognitoOAuth.authorizeURL(
            domain: "https://gnarly-naijei.auth.us-east-1.amazoncognito.com/",
            clientID: "1osnrt38iuqvf5laum1tnj1hdn",
            redirectURI: "https://naijei.com/gnarly/",
            challenge: "abc",
            state: "state-1",
            identityProvider: "Google"
        ))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(url.host, "gnarly-naijei.auth.us-east-1.amazoncognito.com")
        XCTAssertEqual(url.path, "/oauth2/authorize")
        XCTAssertEqual(items["identity_provider"], "Google")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "1osnrt38iuqvf5laum1tnj1hdn")
        XCTAssertEqual(items["redirect_uri"], "https://naijei.com/gnarly/")
        XCTAssertEqual(items["scope"], "openid email")
        XCTAssertEqual(items["code_challenge"], "abc")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "state-1")
        XCTAssertNil(items["client_secret"])
    }

    func testEmailSignInOmitsTheIdentityProvider() throws {
        let url = try XCTUnwrap(CognitoOAuth.authorizeURL(
            domain: CognitoOAuth.defaultDomain,
            clientID: CognitoOAuth.defaultClientID,
            redirectURI: CognitoOAuth.defaultRedirectURI,
            challenge: "abc",
            state: "state-1",
            identityProvider: nil
        ))
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        XCTAssertFalse(names.contains("identity_provider"))
        XCTAssertEqual(CognitoOAuth.tokenEndpoint(domain: CognitoOAuth.defaultDomain)?.path, "/oauth2/token")
    }

    func testPKCEChallengeAndIDTokenClaims() throws {
        XCTAssertEqual(CognitoOAuth.codeChallenge("verifier"), "iMnq5o6zALKXGivsnlom_0F5_WYda32GHkxlV7mq7hQ")
        let payload = Data(#"{"sub":"user-1","email":"NJ277@cornell.edu","email_verified":true,"exp":10}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let claims = try CognitoOAuth.idTokenClaims("header.\(payload).sig")
        XCTAssertEqual(claims.sub, "user-1")
        XCTAssertEqual(claims.email, "NJ277@cornell.edu")
        XCTAssertTrue(claims.emailVerified)
        XCTAssertEqual(claims.exp, 10)
        XCTAssertEqual(CognitoOAuth.callbackParts(redirectURI: "https://naijei.com/gnarly/")?.host, "naijei.com")
        XCTAssertEqual(CognitoOAuth.callbackParts(redirectURI: "https://naijei.com/gnarly/")?.path, "/gnarly/")
        XCTAssertEqual(
            CognitoOAuth.authorizationCodeBody(clientID: "client", code: "auth-code", redirectURI: "http://localhost:5173/", verifier: "verifier"),
            "grant_type=authorization_code&client_id=client&code=auth-code&redirect_uri=http%3A%2F%2Flocalhost%3A5173%2F&code_verifier=verifier"
        )
    }

    func testPlacementUpdateKeepsTheServerRecordJSON() {
        let json = #"{"records":[{"path":"buildings/hall/versions/v1","data":{"status":"published"}},{"path":"buildings/hall","data":{"name":"Hall","activeVersion":null,"latitude":40.1,"acl":{}}}]}"#
        let raw = PackagePublishClient.rawRecordData(in: json, path: "buildings/hall")
        XCTAssertEqual(raw, #"{"name":"Hall","activeVersion":null,"latitude":40.1,"acl":{}}"#)
        XCTAssertEqual(PackagePublishClient.jsonLiteral("buildings/hall"), "\"buildings/hall\"")
    }

    func testLiveAPIDefaultsToAWSWhenThePlistIsEmpty() throws {
        XCTAssertEqual(try GnarlyApiConfig.url(from: CognitoOAuth.defaultAPIBase).host, "m7sgp6qsjkimymyrwa6bilxqzq0acbhx.lambda-url.us-east-1.on.aws")
    }
}
