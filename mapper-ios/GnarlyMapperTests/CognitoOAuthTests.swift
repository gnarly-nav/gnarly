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

    func testPasswordChallengeMatchesTheWebsiteClient() throws {
        XCTAssertEqual(CognitoSrp.poolName(CognitoOAuth.defaultUserPoolID), "pQIUmVbPJ")
        XCTAssertEqual(CognitoSrp.region(CognitoOAuth.defaultUserPoolID), "us-east-1")
        XCTAssertEqual(try CognitoSrp.publicValue(secretHex: "1"), "2")
        XCTAssertEqual(try CognitoSrp.publicValue(secretHex: "02"), "4")
        XCTAssertEqual(CognitoSrp.padHex(BigUInt(limbs: [20])), "14")
        XCTAssertEqual(CognitoSrp.padHex(BigUInt(limbs: [236])), "00ec")
        let secret = String(repeating: "11", count: 32)
        let clientA = try CognitoSrp.publicValue(secretHex: secret)
        XCTAssertEqual(clientA, "f2c4e7407ccfac452a7c7e1034e8388bf70b3aea30007fd146ae4c54b341d252f7752a43f24cd28368a96f455f9ee00eb4312863c2560b7162587cd2c962b588cae47a9ac339433f9fc7d3563c1abb952acc1e3dd565fc9ecde1ac7cc593627494abc14dbb2410bc3dc4a0cf5e6f2f7af643f1d2c888180b50375a28902031b3c7052284d5d32b9dd8ee35c6c0cb9ee52288bcbc52deb224c55391da65ec10e66f8c41cc7d0c12b7a75f171ada3cb4c21fba22c4ad59ad4685cd63080d92d959cc54fcda8022cb856ce27c6e2ae2c81f6f9fa8cad13cfb22dc202b650e14014498bf3afd56c95a8cf956c46e3aedb2f20b4d1d8ebf2e9ef26955e228142b1168b1bfd7383d403ccbb00d89ca6843e39b7a44d7741a063bd4edb9c054606f59c7416327aa574b2f6d910606d9677c5018d07e080cd342ac446d35fd481f7818c780deb9508aeba3483493e43c98c6885e09883b8feb7e903e16468e7a1fc3df0cc55c71d1b3e4b4574d40699be76bca7abdf7938cfb2068cacca3b49b35a49099")
        let key = try CognitoSrp.authenticationKey(
            poolName: "pQIUmVbPJ",
            username: "nj277@cornell.edu",
            password: "hunter2",
            secretHex: secret,
            srpBHex: String(repeating: "2", count: 64),
            saltHex: String(repeating: "ab", count: 16)
        )
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "520fc9074ea5352b6636ae9fedd712f1")
        XCTAssertEqual(
            try CognitoSrp.claimSignature(
                key: key,
                poolName: "pQIUmVbPJ",
                username: "nj277@cornell.edu",
                secretBlock: Data("secret-block".utf8).base64EncodedString(),
                timestamp: "Thu Nov 5 5:04:00 UTC 2026"
            ),
            "JImSfFkTaU6ipA2dMkuPcb3vCT5eSst/JKzuFe3acX8="
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 5, minute: 4, second: 0))!
        XCTAssertEqual(CognitoSrp.timestamp(date), "Thu Nov 5 05:04:00 UTC 2026")
    }
}
