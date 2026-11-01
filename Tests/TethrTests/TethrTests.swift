import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import Tethr

final class FakeServer: ClientTransport, @unchecked Sendable {
    struct Call {
        var method: String
        var path: String
        var authorization: String?
        var body: String
    }

    private let lock = NSLock()
    private var replies: [String: [(Int, String)]]
    private(set) var calls: [Call] = []

    init(_ replies: [String: [(Int, String)]]) {
        self.replies = replies
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let sent = if let body { try await String(collecting: body, upTo: 1 << 20) } else { "" }
        let path = String((request.path ?? "").split(separator: "?").first ?? "")
        let (status, json) = lock.withLock {
            calls.append(Call(method: request.method.rawValue, path: path, authorization: request.headerFields[.authorization], body: sent))
            let key = "\(request.method.rawValue) \(path)"
            guard var queue = replies[key], !queue.isEmpty else { return (500, #"{"code":"unexpected","message":"no reply for \#(key)"}"#) }
            let reply = queue.removeFirst()
            replies[key] = queue.isEmpty ? [reply] : queue
            return reply
        }
        var response = HTTPResponse(status: .init(code: status))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(json))
    }
}

let profileJSON = #"{"id":7,"username":"nathan-sam","name":"Sam","kind":"person","private":true}"#

func tokensJSON(_ access: String) -> String {
    #"{"access_token":"\#(access)","token_type":"bearer","expires_in":86400,"refresh_token":"r-\#(access)","scope":"public","created_at":\#(Int(Date().timeIntervalSince1970))}"#
}

func signedIn(_ server: FakeServer, access: String = "a1", expiresIn: TimeInterval = 3600) -> (Tethr, MemoryStore) {
    let store = MemoryStore(Credentials(accessToken: access, refreshToken: "r-\(access)", expiresAt: Date().addingTimeInterval(expiresIn)))
    return (Tethr(clientID: "tz_test", serverURL: URL(string: "https://api.example")!, store: store, transport: server), store)
}

@Test func deviceSignIn() async throws {
    let server = FakeServer([
        "POST /oauth/device/code": [(200, #"{"device_code":"dc","user_code":"ABCD2345","verification_url":"https://tethr.tv/activate","expires_in":600,"interval":0}"#)],
        "POST /oauth/device/token": [
            (400, #"{"error":"authorization_pending","error_description":"Waiting"}"#),
            (200, tokensJSON("a1")),
        ],
        "GET /v1/profile": [(200, profileJSON)],
    ])
    let store = MemoryStore()
    let tethr = Tethr(clientID: "tz_test", serverURL: URL(string: "https://api.example")!, store: store, transport: server)

    let code = try await tethr.startDeviceSignIn()
    #expect(code.formattedCode == "ABCD-2345")
    #expect(code.directURL.absoluteString == "https://tethr.tv/activate?code=ABCD2345")

    let profile = try await tethr.finishDeviceSignIn(code)
    #expect(profile.username == "nathan-sam")
    #expect(try store.load()?.accessToken == "a1")
    #expect(server.calls.last?.authorization == "Bearer a1")
    #expect(server.calls.filter { $0.path == "/oauth/device/token" }.count == 2)
}

@Test func declinedDeviceSignIn() async throws {
    let server = FakeServer([
        "POST /oauth/device/token": [(418, #"{"error":"access_denied"}"#)],
    ])
    let tethr = Tethr(clientID: "tz_test", serverURL: URL(string: "https://api.example")!, store: MemoryStore(), transport: server)
    let code = DeviceCode(userCode: "ABCD2345", verificationURL: URL(string: "https://tethr.tv/activate")!, expiresAt: .distantFuture, interval: .zero, deviceCode: "dc")
    await #expect(throws: TethrError.declined) { try await tethr.finishDeviceSignIn(code) }
}

@Test func refreshesAfterUnauthorised() async throws {
    let server = FakeServer([
        "GET /v1/profile": [(401, #"{"code":"not_signed_in","message":"Sign in"}"#), (200, profileJSON)],
        "POST /oauth/token": [(200, tokensJSON("a2"))],
    ])
    let (tethr, store) = signedIn(server)
    _ = try await tethr.profile()
    #expect(server.calls.map(\.authorization) == ["Bearer a1", nil, "Bearer a2"])
    #expect(server.calls[1].body.contains(#""refresh_token" : "r-a1""#))
    #expect(try store.load()?.accessToken == "a2")
}

@Test func refreshesBeforeExpiry() async throws {
    let server = FakeServer([
        "POST /oauth/token": [(200, tokensJSON("a2"))],
        "GET /v1/activity": [(200, #"{"latest":"2026-11-01T16:11:17.94962Z","history":"2026-11-01T16:11:17Z","playback":"2026-11-01T16:11:17.865078Z","watchlist":"2026-11-01T16:11:17.94962Z"}"#)],
    ])
    let (tethr, _) = signedIn(server, expiresIn: 60)
    let activity = try await tethr.activity()
    #expect(server.calls.map(\.path) == ["/oauth/token", "/v1/activity"])
    #expect(activity.latest > activity.history)
}

@Test func failedRefreshSignsOut() async throws {
    let server = FakeServer([
        "GET /v1/profile": [(401, #"{"code":"not_signed_in","message":"Sign in"}"#)],
        "POST /oauth/token": [(401, #"{"error":"invalid_grant","error_description":"Expired"}"#)],
    ])
    let (tethr, store) = signedIn(server)
    await #expect(throws: TethrError.notSignedIn) { try await tethr.profile() }
    #expect(try store.load() == nil)
    #expect(await tethr.isSignedIn == false)
}

@Test func signedOutCallsDontReachTheServer() async throws {
    let server = FakeServer([:])
    let tethr = Tethr(clientID: "tz_test", serverURL: URL(string: "https://api.example")!, store: MemoryStore(), transport: server)
    await #expect(throws: TethrError.notSignedIn) { try await tethr.watchlist() }
    #expect(server.calls.isEmpty)
}

@Test func scrobbleSendsEpisodesByNumber() async throws {
    let server = FakeServer([
        "POST /v1/scrobble": [
            (200, #"{"result":"paused","id":1000000000004,"progress":41.5,"item":{"type":"episode","title":{"ids":{"tethr":1000000001,"tmdb":1396}},"episode":{"ids":{"tethr":1000000002},"season":1,"number":2}}}"#),
            (409, #"{"code":"already_watched","message":"Already logged"}"#),
            (404, #"{"code":"not_found","message":"No IDs"}"#),
        ],
    ])
    let (tethr, _) = signedIn(server)
    let result = try await tethr.scrobble(.stop, .episode(show: .tmdb(1396), season: 1, number: 2), progress: 41.5, duration: 2820)
    #expect(result.state == .paused)
    #expect(result.item.kind == .episode)
    #expect(result.item.episode?.number == 2)
    #expect(result.item.title.ids.tmdb == 1396)

    let body = try JSONSerialization.jsonObject(with: Data(server.calls[0].body.utf8)) as? [String: Any]
    let item = body?["item"] as? [String: Any]
    #expect(body?["event"] as? String == "stop")
    #expect(body?["duration_seconds"] as? Double == 2820)
    #expect(item?["type"] as? String == "episode")
    #expect((item?["show"] as? [String: Any])?["tmdb"] as? Int == 1396)

    await #expect(throws: TethrError.alreadyWatched("Already logged")) { try await tethr.scrobble(.stop, .movie(.imdb("tt0133093")), progress: 99) }
    await #expect(throws: TethrError.notFound("No IDs")) { try await tethr.scrobble(.stop, .movie(IDs()), progress: 99) }
}

@Test func historyPages() async throws {
    let server = FakeServer([
        "GET /v1/history": [(200, #"{"items":[{"id":1000000000000,"watched_at":"2024-05-01T20:00:00Z","action":"watch","item":{"type":"movie","title":{"ids":{"tethr":1000000003,"imdb":"tt0133093"}}}}],"total":3,"page":1,"limit":1}"#)],
    ])
    let (tethr, _) = signedIn(server)
    let page = try await tethr.history(of: .movie, limit: 1)
    #expect(page.hasMore)
    #expect(page.watches.first?.item.title.ids.imdb == "tt0133093")
    #expect(page.watches.first?.watchedAt == Date(timeIntervalSince1970: 1_714_593_600))
}
