#if canImport(AuthenticationServices) && !os(tvOS)
import AuthenticationServices
import CryptoKit
import Foundation

extension Tethr {
    @MainActor
    @discardableResult
    public func signIn(redirectURI: URL, presentingFrom anchor: ASPresentationAnchor) async throws -> Profile {
        let verifier = Self.randomString()
        let state = Self.randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let url = serverURL.appending(path: "oauth/authorize").appending(queryItems: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ])

        let callback = try await present(url: url, scheme: redirectURI.scheme, anchor: anchor)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if value("error") == "access_denied" {
            throw TethrError.declined
        }
        guard value("state") == state, let code = value("code") else {
            throw TethrError.rejected(status: 0, code: "bad_callback", message: "Tethr sent the browser back without a sign-in code.")
        }
        return try await signIn(code: code, redirectURI: redirectURI, verifier: verifier)
    }

    @MainActor
    private func present(url: URL, scheme: String?, anchor: ASPresentationAnchor) async throws -> URL {
        let provider = AnchorProvider(anchor: anchor)
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                _ = provider
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
            session.presentationContextProvider = provider
            session.start()
        }
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }
}

private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

extension Data {
    fileprivate func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
