import Fluent
import FluentPostgresDriver
import Foundation
import OpenAPIVapor
import Testing
import Vapor
import VaporTesting

@testable import foobar

struct TestHelpers {
    /// The database the suite runs against: the `db-test` service in `docker-compose.yml`.
    ///
    /// The database *name* is deliberately hardcoded rather than read from the environment. The
    /// port is overridable so CI can point elsewhere, but `foobar_test` is not — a misconfigured
    /// port then fails to connect rather than reaching the development database, which
    /// `withApplication` would proceed to drop every table in.
    private static func databaseConfiguration() -> DatabaseConfigurationFactory {
        .postgres(
            configuration: .init(
                hostname: Environment.get("TEST_DATABASE_HOST") ?? "localhost",
                port: Environment.get("TEST_DATABASE_PORT").flatMap(Int.init) ?? 5433,
                username: "foobar",
                password: "foobar",
                database: "foobar_test",
                tls: .disable
            )
        )
    }

    /// Runs `testBody` against a fully configured `Application` backed by the test database.
    ///
    /// Unlike the in-memory SQLite database this suite used to run on, the PostgreSQL server is
    /// **shared** by every test. Isolation therefore comes from two things working together: the
    /// `.serialized` trait on the suite, so only one test runs at a time, and the `autoRevert()`
    /// below, which drops every table so the next test starts from an empty schema. Removing
    /// either one makes tests interfere with each other.
    ///
    /// The revert and shutdown run on both the success and failure paths, so a failing test still
    /// leaves the database clean for the next one.
    static func withApplication<T>(_ testBody: (Application) async throws -> T) async throws -> T {
        let application = try await Application.make(.testing)

        do {
            // The configuration is passed in rather than left to `configureDatabase`'s default,
            // which resolves to the *development* database.
            try await configureServer(application, databaseConfiguration: databaseConfiguration())

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
