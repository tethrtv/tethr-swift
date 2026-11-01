import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

public final class Tethr: Sendable {
    public static let production = URL(string: "https://api.tethr.tv")!

    public let clientID: String
    public let serverURL: URL
    let api: Client
    let oauth: Client
    let session: Session

    public convenience init(
        clientID: String,
        serverURL: URL = Tethr.production,
        store: any CredentialStore = KeychainStore(),
        urlSession: URLSession = .shared
    ) {
        self.init(clientID: clientID, serverURL: serverURL, store: store, transport: URLSessionTransport(configuration: .init(session: urlSession)))
    }

    init(clientID: String, serverURL: URL, store: any CredentialStore, transport: any ClientTransport) {
        let configuration = Configuration(dateTranscoder: Dates())
        let oauth = Client(serverURL: serverURL, configuration: configuration, transport: transport, middlewares: [ProblemMiddleware()])
        let session = Session(store: store) { refreshToken in
            let tokens = try await unwrapping {
                try await oauth.exchangeToken(body: .json(.init(grantType: .refreshToken, clientId: clientID, refreshToken: refreshToken))).ok.body.json
            }
            return Credentials(tokens)
        }
        self.clientID = clientID
        self.serverURL = serverURL
        self.oauth = oauth
        self.session = session
        api = Client(serverURL: serverURL, configuration: configuration, transport: transport, middlewares: [ProblemMiddleware(), AuthMiddleware(session: session)])
    }

    public var isSignedIn: Bool {
        get async { (try? await session.credentials()) != nil }
    }

    public func signOut() async throws {
        if let credentials = try await session.credentials() {
            _ = try? await unwrapping {
                try await oauth.revokeToken(body: .json(.init(token: credentials.accessToken, clientId: clientID)))
            }
        }
        try await session.set(nil)
    }

    public func startDeviceSignIn() async throws -> DeviceCode {
        let code = try await unwrapping {
            try await oauth.startDeviceSignIn(body: .json(.init(clientId: clientID))).ok.body.json
        }
        guard let url = URL(string: code.verificationUrl) else {
            throw TethrError.rejected(status: 200, code: "bad_verification_url", message: "Tethr sent a sign-in address that couldn’t be read.")
        }
        return DeviceCode(
            userCode: code.userCode,
            verificationURL: url,
            expiresAt: Date().addingTimeInterval(TimeInterval(code.expiresIn)),
            interval: .seconds(code.interval),
            deviceCode: code.deviceCode
        )
    }

    @discardableResult
    public func finishDeviceSignIn(_ code: DeviceCode) async throws -> Profile {
        var wait = code.interval
        while true {
            try await Task.sleep(for: wait)
            if Date() > code.expiresAt {
                throw TethrError.expired
            }
            do {
                let tokens = try await unwrapping {
                    try await oauth.pollDeviceSignIn(body: .json(.init(code: code.deviceCode, clientId: clientID))).ok.body.json
                }
                try await session.set(Credentials(tokens))
                return try await profile()
            } catch TethrError.rejected(400, _, _) {
                continue
            } catch TethrError.rejected(429, _, _) {
                wait += .seconds(5)
            }
        }
    }

    func signIn(code: String, redirectURI: URL, verifier: String) async throws -> Profile {
        let tokens = try await unwrapping {
            try await oauth.exchangeToken(body: .json(.init(
                grantType: .authorizationCode,
                clientId: clientID,
                code: code,
                redirectUri: redirectURI.absoluteString,
                codeVerifier: verifier
            ))).ok.body.json
        }
        try await session.set(Credentials(tokens))
        return try await profile()
    }
}
