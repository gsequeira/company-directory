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

/// How the connection pool is sized, and why it is expressed this way (#83).
///
/// FluentPostgresDriver's `maxConnectionsPerEventLoop` is **per event loop**, and Vapor starts one
/// event loop per core (`Application.swift:145`). Any fixed per-loop number is therefore a
/// different total on every machine, which is how the driver default of 1 came to mean "ten
/// connections on a laptop and two on a CI runner". Fixing the total and dividing puts that
/// arithmetic in the code rather than in a comment somebody has to find.
enum ConnectionPool {
    /// Connections this process will open in total, across every event loop.
    ///
    /// Chosen to sit well under PostgreSQL's default `max_connections` of 100, leaving room for a
    /// `psql` session, a migration run and a second instance during a deploy. It is a capacity
    /// choice and can be raised; the floor below is not.
    static let totalBudget = 32

    /// How long a request waits for a connection before failing.
    ///
    /// The driver default is ten seconds. Every query here takes single-digit milliseconds, so a
    /// request queueing for two seconds is already failing from the caller's side, and a slow
    /// failure is worse than a fast one: it holds the request open while the pool and then the
    /// thread pool fill behind it.
    ///
    /// The trade is deliberate. A burst that would have drained in three seconds now fails instead
    /// of waiting. #50's load harness is what would show whether two seconds is too tight.
    static let acquisitionTimeout: TimeAmount = .seconds(2)

    /// Divides ``totalBudget`` across the event loops, never going below two.
    ///
    /// **Two is a correctness floor, not a tuning choice.** At one connection per loop, any
    /// operation that holds a connection while needing a second one deadlocks until the timeout
    /// above, then fails. A transaction is the obvious case, and it is what #83 was filed for.
    static func connectionsPerEventLoop(coreCount: Int, budget: Int = totalBudget) -> Int {
        max(2, budget / max(1, coreCount))
    }
}

/// Builds the PostgreSQL configuration from the environment.
///
/// `DATABASE_URL` wins when present — that is the form hosting platforms inject. The individual
/// variables are the local-development path, and their defaults match `docker-compose.yml`, so a
/// fresh clone works after `docker compose up -d --wait` with no configuration at all.
///
/// **Both paths set the pool explicitly.** Setting only one of them fixes #83 on this machine and
/// ships it unfixed to whichever platform injects a `DATABASE_URL`.
private func postgresConfiguration() throws -> DatabaseConfigurationFactory {
    let connectionsPerEventLoop = ConnectionPool.connectionsPerEventLoop(coreCount: System.coreCount)

    if let url = Environment.get("DATABASE_URL") {
        return try .postgres(
            url: url,
            maxConnectionsPerEventLoop: connectionsPerEventLoop,
            connectionPoolTimeout: ConnectionPool.acquisitionTimeout
        )
    }

    return .postgres(
        configuration: .init(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init) ?? 5432,
            username: Environment.get("DATABASE_USERNAME") ?? "company_directory",
            password: Environment.get("DATABASE_PASSWORD") ?? "company_directory",
            database: Environment.get("DATABASE_NAME") ?? "company_directory",
            // Correct for a container on this machine, and wrong for anything reachable
            // over a network.
            tls: .disable
        ),
        maxConnectionsPerEventLoop: connectionsPerEventLoop,
        connectionPoolTimeout: ConnectionPool.acquisitionTimeout
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
            Migrations.AddEmployeeNameUniqueness(),
            Migrations.AddEmployeeDepartment(),
            Migrations.BackfillEmployeeDepartment(),
            Migrations.RequireEmployeeDepartment(),
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
