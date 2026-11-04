import Foundation

public struct IDs: Hashable, Sendable {
    public var tethr: Int64?
    public var tmdb: Int?
    public var imdb: String?
    public var tvdb: Int?

    public init(tethr: Int64? = nil, tmdb: Int? = nil, imdb: String? = nil, tvdb: Int? = nil) {
        self.tethr = tethr
        self.tmdb = tmdb
        self.imdb = imdb
        self.tvdb = tvdb
    }

    public static func tethr(_ id: Int64) -> IDs { IDs(tethr: id) }
    public static func tmdb(_ id: Int) -> IDs { IDs(tmdb: id) }
    public static func imdb(_ id: String) -> IDs { IDs(imdb: id) }
    public static func tvdb(_ id: Int) -> IDs { IDs(tvdb: id) }

    init(_ ids: Components.Schemas.Ids?) {
        self.init(tethr: ids?.tethr, tmdb: ids?.tmdb, imdb: ids?.imdb, tvdb: ids?.tvdb)
    }

    var schema: Components.Schemas.Ids {
        .init(tethr: tethr, tmdb: tmdb, imdb: imdb, tvdb: tvdb)
    }
}

public enum Media: Hashable, Sendable {
    case movie(IDs)
    case show(IDs)
    case season(show: IDs, season: Int)
    case episode(show: IDs, season: Int, number: Int)
    case episodeIDs(IDs)

    var schema: Components.Schemas.ItemRef {
        switch self {
        case let .movie(ids):
            .init(_type: .movie, ids: ids.schema)
        case let .show(ids):
            .init(_type: .show, ids: ids.schema)
        case let .season(show, season):
            .init(_type: .season, show: show.schema, season: season)
        case let .episode(show, season, number):
            .init(_type: .episode, show: show.schema, season: season, number: number)
        case let .episodeIDs(ids):
            .init(_type: .episode, ids: ids.schema)
        }
    }

    init(_ ref: Components.Schemas.ItemRef) {
        switch ref._type {
        case .movie:
            self = .movie(IDs(ref.ids))
        case .show:
            self = .show(IDs(ref.ids))
        case .season:
            self = .season(show: IDs(ref.show), season: ref.season ?? 0)
        case .episode:
            if let season = ref.season, let number = ref.number, ref.show != nil {
                self = .episode(show: IDs(ref.show), season: season, number: number)
            } else {
                self = .episodeIDs(IDs(ref.ids))
            }
        }
    }
}

public struct Title: Hashable, Sendable {
    public var ids: IDs
    public var slug: String?
    public var name: String?
    public var originalName: String?
    public var year: Int?
    public var runtimeMinutes: Int?

    init(_ title: Components.Schemas.Title) {
        ids = IDs(title.ids)
        slug = title.slug
        name = title.name
        originalName = title.originalName
        year = title.year
        runtimeMinutes = title.runtimeMinutes
    }
}

public struct Episode: Hashable, Sendable {
    public var ids: IDs
    public var season: Int
    public var number: Int
    public var firstAired: Date?

    init(_ episode: Components.Schemas.Episode) {
        ids = IDs(episode.ids)
        season = episode.season
        number = episode.number
        firstAired = episode.firstAired.flatMap { try? Date($0, strategy: Date.ISO8601FormatStyle().year().month().day()) }
    }
}

public struct Item: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case movie, show, season, episode
    }

    public var kind: Kind
    public var title: Title
    public var season: Int?
    public var episode: Episode?

    init(_ item: Components.Schemas.Item) {
        kind = Kind(rawValue: item._type.rawValue) ?? .movie
        title = Title(item.title)
        season = item.season
        episode = item.episode.map(Episode.init)
    }
}

public struct Profile: Hashable, Sendable {
    public var id: Int64
    public var username: String
    public var name: String
}

public enum PlaybackEvent: String, Hashable, Sendable {
    case start, pause, stop
}

public struct ScrobbleResult: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case watching, paused, watched
    }

    public var state: State
    public var id: Int64?
    public var progress: Double
    public var item: Item
}

public struct Watch: Hashable, Sendable {
    public var id: Int64
    public var watchedAt: Date
    public var action: String
    public var item: Item
}

public struct Play: Hashable, Sendable {
    public var id: Int64
    public var watchedAt: Date
    public var action: String

    init(_ play: Components.Schemas.Play) {
        id = play.id
        watchedAt = play.watchedAt
        action = play.action.rawValue
    }
}

public struct TitleDetail: Hashable, Sendable {
    public struct Resume: Hashable, Sendable {
        public var id: Int64
        public var progress: Double
    }

    public struct Rated: Hashable, Sendable {
        public var id: Int64
        public var rating: Int
        public var ratedAt: Date
    }

    public struct Listed: Hashable, Sendable {
        public var id: Int64
        public var listedAt: Date
    }

    public struct Season: Hashable, Sendable {
        public var number: Int
        public var episodes: [EpisodeState]
    }

    public struct EpisodeState: Hashable, Sendable {
        public var episode: Episode
        public var watches: [Play]
        public var resume: Resume?

        public var watched: Bool { !watches.isEmpty }
    }

    public var kind: Item.Kind
    public var title: Title
    public var watches: [Play]
    public var resume: Resume?
    public var rating: Rated?
    public var listing: Listed?
    public var seasons: [Season]

    init(_ d: Components.Schemas.TitleDetail) {
        kind = d._type == .movie ? .movie : .show
        title = Title(d.title)
        watches = d.watches.map(Play.init)
        resume = d.resume.map { Resume(id: $0.id, progress: $0.progress) }
        rating = d.rating.map { Rated(id: $0.id, rating: $0.rating, ratedAt: $0.ratedAt) }
        listing = d.listing.map { Listed(id: $0.id, listedAt: $0.listedAt) }
        seasons = (d.seasons ?? []).map { season in
            Season(number: season.number, episodes: season.episodes.map { e in
                EpisodeState(
                    episode: Episode(e.episode),
                    watches: e.watches.map(Play.init),
                    resume: e.resume.map { Resume(id: $0.id, progress: $0.progress) }
                )
            })
        }
    }
}

public struct HistoryPage: Hashable, Sendable {
    public var watches: [Watch]
    public var total: Int64
    public var page: Int
    public var limit: Int

    public var hasMore: Bool { Int64(page * limit) < total }
}

public struct ResumePoint: Hashable, Sendable {
    public var id: Int64
    public var progress: Double
    public var pausedAt: Date
    public var item: Item
}

public struct Listing: Hashable, Sendable {
    public var id: Int64
    public var rank: Int
    public var listedAt: Date
    public var notes: String?
    public var item: Item
}

public struct Rating: Hashable, Sendable {
    public var id: Int64
    public var rating: Int
    public var ratedAt: Date
    public var item: Item
}

public struct UpNextEntry: Hashable, Sendable {
    public struct Resume: Hashable, Sendable {
        public var id: Int64
        public var progress: Double
    }

    public var show: Title
    public var next: Episode
    public var lastWatchedAt: Date
    public var aired: Int
    public var watched: Int
    public var resume: Resume?

    public var remaining: Int { aired - watched }
}

public struct Activity: Hashable, Sendable {
    public var latest: Date
    public var history: Date
    public var playback: Date
    public var watchlist: Date
    public var ratings: Date
}

public struct SyncResult: Hashable, Sendable {
    public var added: Int
    public var existing: Int
    public var notFound: [Media]

    init(_ result: Components.Schemas.SyncResult) {
        added = result.added
        existing = result.existing
        notFound = result.notFound.map(Media.init)
    }
}

public struct DeviceCode: Hashable, Sendable {
    public var userCode: String
    public var verificationURL: URL
    public var expiresAt: Date
    public var interval: Duration
    var deviceCode: String

    public var formattedCode: String {
        userCode.count == 8 ? "\(userCode.prefix(4))-\(userCode.suffix(4))" : userCode
    }

    public var directURL: URL {
        verificationURL.appending(queryItems: [URLQueryItem(name: "code", value: userCode)])
    }
}
