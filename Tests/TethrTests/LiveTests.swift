import Foundation
import Testing

@testable import Tethr

let live = ProcessInfo.processInfo.environment["TETHR_LIVE_API"].flatMap(URL.init(string:))

@Test(.enabled(if: live != nil, "set TETHR_LIVE_API, TETHR_LIVE_CLIENT_ID and TETHR_LIVE_TOKEN to run against a server"))
func againstAServer() async throws {
    let env = ProcessInfo.processInfo.environment
    let store = MemoryStore(Credentials(accessToken: env["TETHR_LIVE_TOKEN"] ?? "", refreshToken: "", expiresAt: .distantFuture))
    let tethr = Tethr(clientID: env["TETHR_LIVE_CLIENT_ID"] ?? "", serverURL: live!, store: store)

    let profile = try await tethr.profile()
    let before = try await tethr.history()

    let episode = Media.episode(show: .tmdb(84958), season: 1, number: 1)
    #expect(try await tethr.scrobble(.start, episode, progress: 1).state == .watching)
    let paused = try await tethr.scrobble(.pause, episode, progress: 40, duration: 3000)
    #expect(paused.state == .paused)
    #expect(try await tethr.resumePoints(of: .episode).contains { $0.id == paused.id })
    let watched = try await tethr.scrobble(.stop, episode, progress: 96)
    #expect(watched.state == .watched)
    await #expect(throws: TethrError.self) { try await tethr.scrobble(.stop, episode, progress: 97) }

    let after = try await tethr.history()
    #expect(after.total == before.total + 1)
    #expect(after.watches.first?.item.episode?.season == 1)

    let added = try await tethr.addToWatchlist(.movie(.imdb("tt0816692")), notes: "rewatch")
    #expect(added.added + added.existing == 1)
    let listing = try #require(try await tethr.watchlist(of: .movie).first { $0.item.title.ids.imdb == "tt0816692" })
    try await tethr.removeFromWatchlist(id: listing.id)
    try await tethr.removeWatch(id: try #require(watched.id))
    #expect(try await tethr.history().total == before.total)

    let activity = try await tethr.activity()
    #expect(activity.latest >= activity.history)
    print("signed in as \(profile.username); round trip ok")
}
