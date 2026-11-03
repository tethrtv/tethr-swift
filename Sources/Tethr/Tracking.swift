import Foundation

extension Tethr {
    public func profile() async throws -> Profile {
        let p = try await unwrapping { try await api.getProfile().ok.body.json }
        return Profile(id: p.id, username: p.username, name: p.name)
    }

    @discardableResult
    public func scrobble(_ event: PlaybackEvent, _ media: Media, progress: Double, duration: TimeInterval? = nil) async throws -> ScrobbleResult {
        let request = Components.Schemas.ScrobbleRequest(
            event: .init(rawValue: event.rawValue)!,
            progress: min(max(progress, 0), 100),
            durationSeconds: duration,
            item: media.schema
        )
        let r = try await unwrapping { try await api.scrobble(body: .json(request)).ok.body.json }
        return ScrobbleResult(state: .init(rawValue: r.result.rawValue)!, id: r.id, progress: r.progress, item: Item(r.item))
    }

    public func history(of kind: Item.Kind? = nil, titleID: Int64? = nil, page: Int = 1, limit: Int = 50) async throws -> HistoryPage {
        let query = Operations.ListHistory.Input.Query(
            _type: kind.flatMap { .init(rawValue: $0.rawValue) },
            titleId: titleID,
            page: page,
            limit: limit
        )
        let h = try await unwrapping { try await api.listHistory(query: query).ok.body.json }
        let watches = h.items.map { Watch(id: $0.id, watchedAt: $0.watchedAt, action: $0.action.rawValue, item: Item($0.item)) }
        return HistoryPage(watches: watches, total: h.total, page: h.page, limit: h.limit)
    }

    @discardableResult
    public func addToHistory(_ media: Media, watchedAt: Date? = nil) async throws -> SyncResult {
        try await addToHistory([(media, watchedAt)])
    }

    @discardableResult
    public func addToHistory(_ watches: [(Media, Date?)]) async throws -> SyncResult {
        let body = Components.Schemas.NewWatches(items: watches.map { .init(item: $0.0.schema, watchedAt: $0.1) })
        return SyncResult(try await unwrapping { try await api.addHistory(body: .json(body)).ok.body.json })
    }

    public func removeWatch(id: Int64) async throws {
        _ = try await unwrapping { try await api.removeWatch(path: .init(id: id)).noContent }
    }

    public func resumePoints(of kind: Item.Kind? = nil) async throws -> [ResumePoint] {
        let query = Operations.ListPlayback.Input.Query(_type: kind.flatMap { .init(rawValue: $0.rawValue) })
        let points = try await unwrapping { try await api.listPlayback(query: query).ok.body.json }
        return points.map { ResumePoint(id: $0.id, progress: $0.progress, pausedAt: $0.pausedAt, item: Item($0.item)) }
    }

    public func removeResumePoint(id: Int64) async throws {
        _ = try await unwrapping { try await api.removePlayback(path: .init(id: id)).noContent }
    }

    public func watchlist(of kind: Item.Kind? = nil) async throws -> [Listing] {
        let query = Operations.ListWatchlist.Input.Query(_type: kind.flatMap { .init(rawValue: $0.rawValue) })
        let listings = try await unwrapping { try await api.listWatchlist(query: query).ok.body.json }
        return listings.map { Listing(id: $0.id, rank: $0.rank, listedAt: $0.listedAt, notes: $0.notes, item: Item($0.item)) }
    }

    @discardableResult
    public func addToWatchlist(_ media: Media, notes: String? = nil) async throws -> SyncResult {
        try await addToWatchlist([(media, notes)])
    }

    @discardableResult
    public func addToWatchlist(_ entries: [(Media, String?)]) async throws -> SyncResult {
        let body = Components.Schemas.NewListings(items: entries.map { .init(item: $0.0.schema, notes: $0.1) })
        return SyncResult(try await unwrapping { try await api.addToWatchlist(body: .json(body)).ok.body.json })
    }

    public func removeFromWatchlist(id: Int64) async throws {
        _ = try await unwrapping { try await api.removeFromWatchlist(path: .init(id: id)).noContent }
    }

    public func ratings(of kind: Item.Kind? = nil, rated: [Int] = []) async throws -> [Rating] {
        let query = Operations.ListRatings.Input.Query(
            _type: kind.flatMap { .init(rawValue: $0.rawValue) },
            rating: rated.isEmpty ? nil : rated
        )
        let ratings = try await unwrapping { try await api.listRatings(query: query).ok.body.json }
        return ratings.map { Rating(id: $0.id, rating: $0.rating, ratedAt: $0.ratedAt, item: Item($0.item)) }
    }

    @discardableResult
    public func rate(_ media: Media, rating: Int, ratedAt: Date? = nil) async throws -> SyncResult {
        try await rate([(media, rating, ratedAt)])
    }

    @discardableResult
    public func rate(_ ratings: [(Media, Int, Date?)]) async throws -> SyncResult {
        let body = Components.Schemas.NewRatings(items: ratings.map { .init(item: $0.0.schema, rating: $0.1, ratedAt: $0.2) })
        return SyncResult(try await unwrapping { try await api.rate(body: .json(body)).ok.body.json })
    }

    public func removeRating(id: Int64) async throws {
        _ = try await unwrapping { try await api.removeRating(path: .init(id: id)).noContent }
    }

    public func upNext() async throws -> [UpNextEntry] {
        let entries = try await unwrapping { try await api.getUpNext().ok.body.json }
        return entries.map {
            UpNextEntry(
                show: Title(ids: IDs($0.show.ids), name: $0.show.name, originalName: $0.show.originalName, year: $0.show.year),
                next: Episode($0.next),
                lastWatchedAt: $0.lastWatchedAt,
                aired: $0.aired,
                watched: $0.watched,
                resume: $0.resume.map { UpNextEntry.Resume(id: $0.id, progress: $0.progress) }
            )
        }
    }

    public func hideFromUpNext(showID: Int64) async throws {
        _ = try await unwrapping { try await api.hideFromUpNext(path: .init(id: showID)).noContent }
    }

    public func showInUpNext(showID: Int64) async throws {
        _ = try await unwrapping { try await api.showInUpNext(path: .init(id: showID)).noContent }
    }

    public func activity() async throws -> Activity {
        let a = try await unwrapping { try await api.getActivity().ok.body.json }
        return Activity(latest: a.latest, history: a.history, playback: a.playback, watchlist: a.watchlist, ratings: a.ratings)
    }
}
