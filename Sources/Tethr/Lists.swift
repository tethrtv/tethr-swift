import Foundation

extension Tethr {
    public func lists() async throws -> [TethrList] {
        try await unwrapping { try await api.listLists().ok.body.json }.map(TethrList.init)
    }

    public func followedLists() async throws -> [TethrList] {
        try await unwrapping { try await api.listFollowedLists().ok.body.json }.map(TethrList.init)
    }

    public func browseLists(order: TethrList.Order = .newest, official: Bool? = nil, matching words: String? = nil, page: Int = 1, limit: Int = 20) async throws -> ListsPage {
        let query = Operations.BrowseLists.Input.Query(
            order: .init(rawValue: order.rawValue),
            official: official,
            q: words,
            page: page,
            limit: limit
        )
        let p = try await unwrapping { try await api.browseLists(query: query).ok.body.json }
        return ListsPage(lists: p.lists.map(TethrList.init), total: Int64(p.total), page: p.page, limit: p.limit)
    }

    public func list(id: Int64) async throws -> TethrList {
        TethrList(try await unwrapping { try await api.getList(path: .init(id: id)).ok.body.json })
    }

    public func listItems(id: Int64, hidingWatched: Bool = false, page: Int = 1, limit: Int = 100) async throws -> ListItemsPage {
        let query = Operations.ListListItems.Input.Query(hideWatched: hidingWatched ? true : nil, page: page, limit: limit)
        let p = try await unwrapping { try await api.listListItems(path: .init(id: id), query: query).ok.body.json }
        return ListItemsPage(
            list: TethrList(p.list),
            items: p.items.map {
                Listing(
                    id: $0.id, rank: $0.rank, listedAt: $0.listedAt, notes: $0.notes, item: Item($0.item),
                    progress: $0.progress.map { Listing.Progress(watched: $0.watched, total: $0.total, lastWatchedAt: $0.lastWatchedAt) }
                )
            },
            total: Int64(p.total),
            page: p.page,
            limit: p.limit
        )
    }

    @discardableResult
    public func follow(listID: Int64) async throws -> TethrList {
        TethrList(try await unwrapping { try await api.followList(path: .init(id: listID)).ok.body.json })
    }

    public func unfollow(listID: Int64) async throws {
        _ = try await unwrapping { try await api.unfollowList(path: .init(id: listID)).noContent }
    }
}
