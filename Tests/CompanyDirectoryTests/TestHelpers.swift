import Fluent
import FluentPostgresDriver
import Foundation
import OpenAPIVapor
import Testing
import Vapor
import VaporTesting

@testable import CompanyDirectory

struct TestHelpers {
    /// The database the suite runs against: the `db-test` service in `docker-compose.yml`.
    ///
    /// The database *name* is deliberately hardcoded rather than read from the environment. The
    /// port is overridable so CI can point elsewhere, but `company_directory_test` is not — a misconfigured
    /// port then fails to connect rather than reaching the development database, which
    /// `withApplication` would proceed to drop every table in.
    private static func databaseConfiguration() -> DatabaseConfigurationFactory {
        .postgres(
            configuration: .init(
                hostname: Environment.get("TEST_DATABASE_HOST") ?? "localhost",
                port: Environment.get("TEST_DATABASE_PORT").flatMap(Int.init) ?? 5433,
                username: "company_directory",
                password: "company_directory",
                database: "company_directory_test",
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

    /// Creates a department and returns its id.
    ///
    /// Since #18 an employee cannot exist without one, so most employee tests now open with this
    /// line. It goes through the API rather than inserting the model directly, so the setup keeps
    /// exercising the same path a client takes — a regression in `createDepartment` fails these
    /// tests loudly instead of leaving them passing against data no client could have produced.
    static func createDepartment(
        _ application: Application,
        named name: String = "Engineering"
    ) async throws -> Int32 {
        let response = try await application.sendRequest(
            .POST, "/api/departments",
            body: Components.Schemas.CreateDepartmentRequest(name: name))

        try #require(response.status == .created)

        let department = try response.content.decode(Components.Schemas.Department.self)

        return Int32(department.id)
    }
}

extension Application {
    func sendRequest<Body: Encodable>(_ method: HTTPMethod, _ path: String, body: Body) async throws
        -> TestingHTTPResponse
    {
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
