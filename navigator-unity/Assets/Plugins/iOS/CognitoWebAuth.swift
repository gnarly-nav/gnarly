import AuthenticationServices
import Foundation
import UIKit

/// Presents Cognito's hosted UI and returns the redirect to Unity.
/// Uses the https callback already registered for the website (iOS 17.4+).
private let cognitoLock = NSLock()
private var cognitoResult: String?
private var cognitoSession: ASWebAuthenticationSession?
private let cognitoPresenter = CognitoWebAuthPresenter()

@_cdecl("GnarlyCognitoBegin")
public func gnarlyCognitoBegin(_ authorizeRaw: UnsafePointer<CChar>?, _ redirectRaw: UnsafePointer<CChar>?) {
    let authorize = authorizeRaw.map { String(cString: $0) } ?? ""
    let redirect = redirectRaw.map { String(cString: $0) } ?? ""
    DispatchQueue.main.async {
        cognitoLock.lock()
        cognitoResult = nil
        cognitoLock.unlock()
        guard let url = URL(string: authorize),
              let parts = URLComponents(string: redirect),
              let host = parts.host, !host.isEmpty else {
            cognitoStore("err\nThe Cognito sign-in URL is invalid.")
            return
        }
        let path = parts.path.isEmpty ? "/" : parts.path
        guard #available(iOS 17.4, *) else {
            cognitoStore("err\nSign in needs iOS 17.4 or later.")
            return
        }
        let session = ASWebAuthenticationSession(url: url, callback: .https(host: host, path: path)) { callbackURL, error in
            if let callbackURL {
                cognitoStore("ok\n" + callbackURL.absoluteString)
                return
            }
            let ns = error as NSError?
            if ns?.domain == ASWebAuthenticationSessionError.errorDomain,
               ns?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                cognitoStore("err\nSign-in was canceled.")
            } else {
                cognitoStore("err\n" + (error?.localizedDescription ?? "Sign-in failed."))
            }
        }
        session.presentationContextProvider = cognitoPresenter
        session.prefersEphemeralWebBrowserSession = false
        cognitoSession = session
        if !session.start() {
            cognitoStore("err\nCould not open the sign-in page.")
        }
    }
}

@_cdecl("GnarlyCognitoPoll")
public func gnarlyCognitoPoll() -> UnsafeMutablePointer<CChar>? {
    cognitoLock.lock()
    let value = cognitoResult
    cognitoResult = nil
    cognitoLock.unlock()
    guard let value else { return nil }
    return strdup(value)
}

@_cdecl("GnarlyCognitoFree")
public func gnarlyCognitoFree(_ value: UnsafeMutablePointer<CChar>?) {
    free(value)
}

private func cognitoStore(_ value: String) {
    cognitoLock.lock()
    cognitoResult = value
    cognitoLock.unlock()
}

private final class CognitoWebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        if let window { return window }
        if let scene { return UIWindow(windowScene: scene) }
        return UIWindow()
    }
}
