import Foundation
import OpenAPIRuntime

public enum TethrError: Error, Hashable, Sendable {
    case notSignedIn
    case notFound(String)
    case alreadyWatched(String)
    case progressTooLow
    case expired
    case declined
    case rejected(status: Int, code: String, message: String)

    init(status: Int, body: Data) {
        struct Problem: Decodable {
            var code: String?
            var message: String?
            var error: String?
            var errorDescription: String?

            enum CodingKeys: String, CodingKey {
                case code, message, error
                case errorDescription = "error_description"
            }
        }
        let problem = try? JSONDecoder().decode(Problem.self, from: body)
        let code = problem?.code ?? problem?.error ?? ""
        let message = problem?.message ?? problem?.errorDescription ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch (status, code) {
        case (401, "invalid_client"):
            self = .rejected(status: status, code: code, message: message)
        case (401, _):
            self = .notSignedIn
        case (404, "invalid_device_code"), (409, "already_used"), (410, _):
            self = .expired
        case (418, _):
            self = .declined
        case (404, _):
            self = .notFound(message)
        case (409, "already_watched"):
            self = .alreadyWatched(message)
        case (422, _):
            self = .progressTooLow
        default:
            self = .rejected(status: status, code: code, message: message)
        }
    }
}

extension TethrError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "You’re not signed in to Tethr."
        case let .notFound(message), let .alreadyWatched(message), let .rejected(_, _, message):
            message
        case .progressTooLow:
            "Progress under 1% isn’t saved."
        case .expired:
            "That code has expired. Start signing in again."
        case .declined:
            "Signing in was turned down."
        }
    }
}

func unwrapping<T>(_ operation: () async throws -> T) async throws -> T {
    do {
        return try await operation()
    } catch let error as ClientError {
        throw error.underlyingError
    }
}
