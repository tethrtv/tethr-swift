import Foundation
import Security

public struct Credentials: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    init(_ tokens: Components.Schemas.Tokens) {
        self.init(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(tokens.createdAt + Int64(tokens.expiresIn)))
        )
    }
}

public protocol CredentialStore: Sendable {
    func load() throws -> Credentials?
    func save(_ credentials: Credentials?) throws
}

public struct KeychainStore: CredentialStore {
    public var service: String
    public var accessGroup: String?

    public init(service: String = "tv.tethr", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "credentials",
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func load() throws -> Credentials? {
        var query = query
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    public func save(_ credentials: Credentials?) throws {
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw KeychainError(status: deleted)
        }
        guard let credentials else { return }
        var item = query
        item[kSecValueData as String] = try JSONEncoder().encode(credentials)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }
}

public struct KeychainError: Error, Sendable {
    public var status: OSStatus
}

public final class MemoryStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: Credentials?

    public init(_ credentials: Credentials? = nil) {
        self.credentials = credentials
    }

    public func load() throws -> Credentials? {
        lock.withLock { credentials }
    }

    public func save(_ credentials: Credentials?) throws {
        lock.withLock { self.credentials = credentials }
    }
}

actor Session {
    private let store: any CredentialStore
    private let refresher: @Sendable (String) async throws -> Credentials
    private var loaded = false
    private var cached: Credentials?
    private var refreshing: Task<Credentials, any Error>?

    init(store: any CredentialStore, refresher: @escaping @Sendable (String) async throws -> Credentials) {
        self.store = store
        self.refresher = refresher
    }

    func credentials() throws -> Credentials? {
        if !loaded {
            cached = try store.load()
            loaded = true
        }
        return cached
    }

    func set(_ credentials: Credentials?) throws {
        try store.save(credentials)
        cached = credentials
        loaded = true
    }

    func accessToken() async throws -> String? {
        guard let current = try credentials() else { return nil }
        if current.expiresAt.timeIntervalSinceNow > 300 {
            return current.accessToken
        }
        return try await refresh(after: current.accessToken)?.accessToken
    }

    func refresh(after rejected: String) async throws -> Credentials? {
        guard let current = try credentials() else { return nil }
        if current.accessToken != rejected {
            return current
        }
        if let refreshing {
            return try await refreshing.value
        }
        let task = Task { [refresher] in try await refresher(current.refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            try set(fresh)
            return fresh
        } catch TethrError.notSignedIn {
            try set(nil)
            throw TethrError.notSignedIn
        }
    }
}
