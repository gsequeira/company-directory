import Fluent
import FluentSQLiteDriver
import Foundation
import OpenAPIVapor
import Testing
import Vapor
import VaporTesting

@testable import foobar

struct TestHelpers {
    static func withApplication<T>(_ testBody: (Application) async throws -> T) async throws -> T {
        let application = try await Application.make(.testing)

        do {
            application.databases.use(.sqlite(.memory), as: .sqlite)
            try await configureServer(application)

            let result = try await testBody(application)

            try await application.autoRevert()
            try await application.asyncShutdown()

            return result
        } catch {
            try? await application.autoRevert()
            try await application.asyncShutdown()

            throw error
        }
    }
}

extension Application {
    func sendRequest<Body: Encodable>(_ method: HTTPMethod, _ path: String, body: Body) async throws -> TestingHTTPResponse {
        try await sendRequest(method, path) { req in
            req.headers.contentType = .json
            try req.content.encode(body, as: .json)
        }
    }

    func sendRequest(_ method: HTTPMethod, _ path: String, body: Data) async throws -> TestingHTTPResponse {
        try await sendRequest(method, path) { req in
            req.headers.contentType = .json
            req.body = .init(data: body)
        }
    }

    func sendRequest(_ method: HTTPMethod, _ path: String) async throws -> TestingHTTPResponse {
        try await sendRequest(method, path) { _ in }
    }
}
