import Foundation
import HTTPTypes
import OpenAPIRuntime

struct ProblemMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard response.status.code >= 400 else {
            return (response, responseBody)
        }
        let data = if let responseBody { try await Data(collecting: responseBody, upTo: 1 << 16) } else { Data() }
        throw TethrError(status: response.status.code, body: data)
    }
}

struct AuthMiddleware: ClientMiddleware {
    let session: Session

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard let token = try await session.accessToken() else {
            throw TethrError.notSignedIn
        }
        let data = if let body { try await Data(collecting: body, upTo: 4 << 20) } else { Data?.none }
        var signed = request
        signed.headerFields[.authorization] = "Bearer \(token)"
        let (response, responseBody) = try await next(signed, data.map { HTTPBody($0) }, baseURL)
        guard response.status == .unauthorized, let fresh = try await session.refresh(after: token) else {
            return (response, responseBody)
        }
        signed.headerFields[.authorization] = "Bearer \(fresh.accessToken)"
        return try await next(signed, data.map { HTTPBody($0) }, baseURL)
    }
}

struct Dates: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        date.formatted(.iso8601)
    }

    func decode(_ string: String) throws -> Date {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try Date.ISO8601FormatStyle().parse(string)
    }
}
