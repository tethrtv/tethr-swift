import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import Tethr

final class FakeServer: ClientTransport, @unchecked Sendable {
    struct Call {
        var method: String
        var path: String
        var query: String
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
        let parts = (request.path ?? "").split(separator: "?", maxSplits: 1)
        let path = String(parts.first ?? "")
        let query = parts.count > 1 ? String(parts[1]) : ""
        let (status, json) = lock.withLock {
            calls.append(Call(method: request.method.rawValue, path: path, query: query, authorization: request.headerFields[.authorization], body: sent))
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
        "GET /v1/activity": [(200, #"{"latest":"2026-11-01T16:11:17.94962Z","history":"2026-11-01T16:11:17Z","playback":"2026-11-01T16:11:17.865078Z","watchlist":"2026-11-01T16:11:17.94962Z","ratings":"2026-11-01T16:10:02Z","lists":"2026-11-01T16:09:00Z"}"#)],
    ])
    let (tethr, _) = signedIn(server, expiresIn: 60)
    let activity = try await tethr.activity()
    #expect(server.calls.map(\.path) == ["/oauth/token", "/v1/activity"])
    #expect(activity.latest > activity.history)
    #expect(activity.ratings < activity.history)
    #expect(activity.lists < activity.ratings)
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
        "GET /v1/history": [(200, #"{"items":[{"id":1000000000000,"watched_at":"2024-05-01T20:00:00Z","precision":"time","action":"watch","item":{"type":"movie","title":{"ids":{"tethr":1000000003,"imdb":"tt0133093"},"name":"The Matrix","original_name":"The Matrix","year":1999}}}],"total":3,"page":1,"limit":1}"#)],
    ])
    let (tethr, _) = signedIn(server)
    let page = try await tethr.history(of: .movie, limit: 1)
    #expect(page.hasMore)
    #expect(page.watches.first?.item.title.ids.imdb == "tt0133093")
    #expect(page.watches.first?.item.title.name == "The Matrix")
    #expect(page.watches.first?.item.title.originalName == "The Matrix")
    #expect(page.watches.first?.item.title.year == 1999)
    #expect(page.watches.first?.watchedAt == Date(timeIntervalSince1970: 1_714_593_600))
}

@Test func upNext() async throws {
    let server = FakeServer([
        "GET /v1/up-next": [(200, #"[{"show":{"ids":{"tethr":1000000010,"tmdb":83867}},"next":{"ids":{"tethr":1000000092,"tmdb":3745383},"season":1,"number":4,"first_aired":"2022-09-28"},"last_watched_at":"2026-11-01T16:12:13.44368Z","aired":24,"watched":1,"resume":{"id":1000000000007,"progress":12.5}}]"#)],
        "PUT /v1/up-next/hidden/1000000010": [(204, "")],
    ])
    let (tethr, _) = signedIn(server)
    let next = try await tethr.upNext()
    #expect(next.count == 1)
    #expect(next[0].next.season == 1 && next[0].next.number == 4)
    #expect(next[0].next.firstAired == Date(timeIntervalSince1970: 1_664_323_200))
    #expect(next[0].remaining == 23)
    #expect(next[0].resume?.progress == 12.5)
    try await tethr.hideFromUpNext(showID: 1000000010)
    #expect(server.calls.last?.method == "PUT")
}

@Test func ratings() async throws {
    let server = FakeServer([
        "GET /v1/ratings": [(200, #"[{"id":1000000000020,"rating":9,"rated_at":"2024-05-01T20:00:00Z","item":{"type":"movie","title":{"ids":{"tethr":1000000003,"imdb":"tt0133093"}}}}]"#)],
        "POST /v1/ratings": [(200, #"{"added":1,"existing":0,"not_found":[{"type":"movie","ids":{"imdb":"tt0816692"}}]}"#)],
        "DELETE /v1/ratings/1000000000020": [(204, "")],
    ])
    let (tethr, _) = signedIn(server)
    let ratings = try await tethr.ratings(of: .movie, rated: [9, 10])
    #expect(server.calls[0].query == "type=movie&rating=9,10")
    #expect(ratings.first?.rating == 9)
    #expect(ratings.first?.ratedAt == Date(timeIntervalSince1970: 1_714_593_600))
    #expect(ratings.first?.item.title.ids.imdb == "tt0133093")

    let result = try await tethr.rate([
        (.episode(show: .tmdb(1396), season: 1, number: 2), 8, Date(timeIntervalSince1970: 1_714_593_600)),
        (.movie(.imdb("tt0816692")), 7, nil),
    ])
    #expect(result.added == 1)
    #expect(result.notFound == [.movie(.imdb("tt0816692"))])
    let body = try JSONSerialization.jsonObject(with: Data(server.calls[1].body.utf8)) as? [String: Any]
    let items = body?["items"] as? [[String: Any]]
    #expect(items?.map { $0["rating"] as? Int } == [8, 7])
    #expect(items?[0]["rated_at"] as? String == "2024-05-01T20:00:00Z")
    #expect(items?[1]["rated_at"] == nil)

    try await tethr.rate(.show(.tmdb(1396)), rating: 10)
    #expect(server.calls[2].body.contains(#""rating" : 10"#))
    try await tethr.removeRating(id: 1000000000020)
    #expect(server.calls.last?.method == "DELETE")
}

@Test func titleDetail() async throws {
    let server = FakeServer([
        "GET /v1/titles/breaking-bad-2008": [(200, #"{"type":"show","title":{"ids":{"tethr":1000000000,"tmdb":1396},"slug":"breaking-bad-2008","name":"Breaking Bad","year":2008,"runtime_minutes":47},"watches":[],"rating":{"id":1000000000020,"rating":9,"rated_at":"2024-05-01T20:00:00Z"},"seasons":[{"number":1,"episodes":[{"episode":{"ids":{"tethr":1000000001},"season":1,"number":1,"first_aired":"2008-01-20"},"watches":[{"id":1000000000001,"watched_at":"2024-05-01T20:00:00Z","precision":"time","action":"scrobble"}]},{"episode":{"ids":{"tethr":1000000002},"season":1,"number":2},"watches":[],"resume":{"id":1000000000007,"progress":38}}]}]}"#)],
        "GET /v1/titles/no-such-show-1999": [(404, #"{"code":"not_found","message":"No such title"}"#)],
    ])
    let (tethr, _) = signedIn(server)
    let show = try await tethr.title("breaking-bad-2008")
    #expect(show.kind == .show)
    #expect(show.title.slug == "breaking-bad-2008")
    #expect(show.title.runtimeMinutes == 47)
    #expect(show.rating?.rating == 9)
    #expect(show.listing == nil)
    #expect(show.seasons.first?.episodes.map(\.watched) == [true, false])
    #expect(show.seasons.first?.episodes.last?.resume?.progress == 38)
    #expect(show.seasons.first?.episodes.first?.watches.first?.action == "scrobble")
    await #expect(throws: TethrError.notFound("No such title")) { try await tethr.title("no-such-show-1999") }
}

@Test func search() async throws {
    let server = FakeServer([
        "GET /v1/search": [(200, #"[{"type":"movie","title":{"ids":{"tethr":1000000003,"tmdb":27205},"slug":"inception-2010","name":"Inception","year":2010}}]"#)],
    ])
    let (tethr, _) = signedIn(server)
    let found = try await tethr.search("in", of: .movie)
    #expect(server.calls[0].query == "q=in&type=movie")
    #expect(found.first?.title.slug == "inception-2010")
    #expect(found.first?.kind == .movie)
}
