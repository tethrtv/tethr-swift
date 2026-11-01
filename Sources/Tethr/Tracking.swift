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

    public func activity() async throws -> Activity {
        let a = try await unwrapping { try await api.getActivity().ok.body.json }
        return Activity(latest: a.latest, history: a.history, playback: a.playback, watchlist: a.watchlist)
    }
}
