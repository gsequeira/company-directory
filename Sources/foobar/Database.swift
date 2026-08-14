import Fluent
import FluentPostgresDriver
import Foundation
import Vapor

/// Errors surfaced by `configureDatabase(application:)` — startup failures only, not query errors.
///
/// Named `DatabaseSetupError` rather than `DatabaseError` deliberately: FluentKit declares a
/// `DatabaseError` protocol that drivers conform their own error types to, and a same-named type
/// here shadows it for every file in this module. See `Docs/FLUENT.md`.
enum DatabaseSetupError: Error, LocalizedError {
    /// Thrown when `autoMigrate()` fails. Carries the underlying error's description.
    case migrationFailed(String)
    /// Thrown when database setup fails for any other reason.
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .migrationFailed(let message):
            return "Database migration failed: \(message)"
        case .configurationFailed(let message):
            return "Database configuration failed: \(message)"
        }
    }
}

/// Builds the PostgreSQL configuration from the environment.
///
/// `DATABASE_URL` wins when present — that is the form hosting platforms inject. The individual
/// variables are the local-development path, and their defaults match `docker-compose.yml`, so a
/// fresh clone works after `docker compose up -d --wait` with no configuration at all.
private func postgresConfiguration() throws -> DatabaseConfigurationFactory {
    if let url = Environment.get("DATABASE_URL") {
        return try .postgres(url: url)
    }

    return .postgres(
        configuration: .init(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init) ?? 5432,
            username: Environment.get("DATABASE_USERNAME") ?? "foobar",
            password: Environment.get("DATABASE_PASSWORD") ?? "foobar",
            database: Environment.get("DATABASE_NAME") ?? "foobar",
            // Correct for a container on this machine, and wrong for anything reachable
            // over a network.
            tls: .disable
        )
    )
}

/// Registers the PostgreSQL database, adds every migration, and runs them.
///
/// - Parameter configuration: The database to use. Defaults to the environment-derived one built
///   by `postgresConfiguration()`; the test suite passes its own so that it never touches the
///   development database. Making this injectable is what stops `autoRevert()` in a test from
///   dropping real tables.
///
/// - Throws: `DatabaseSetupError.migrationFailed` or `DatabaseSetupError.configurationFailed`.
func configureDatabase(
    application: Application,
    configuration: DatabaseConfigurationFactory? = nil
) async throws {
    do {
        application.databases.use(try configuration ?? postgresConfiguration(), as: .psql)

        // Order matters and is append-only: Fluent runs new migrations in the order listed,
        // recording each in `_fluent_migrations` so it is never run twice.
        application.migrations.add([
            Migrations.CreateDepartments(),
            Migrations.CreateEmployees(),
            Migrations.AddEmployeeNameUniqueness()
        ])

        try await application.autoMigrate()
    } catch {
        // `autoMigrate()` does not surface a typed error distinguishing migration failure from
        // configuration failure, so the message is matched instead. This is fragile: any change
        // to the wording upstream, or a localized description, silently reclassifies the error
        // as `.configurationFailed`.
        let errorMessage = error.localizedDescription
        if errorMessage.contains("migration") || errorMessage.contains("Migration") {
            throw DatabaseSetupError.migrationFailed(errorMessage)
        } else {
            throw DatabaseSetupError.configurationFailed(errorMessage)
        }
    }
}
