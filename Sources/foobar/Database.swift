import Fluent
import FluentSQLiteDriver
import Foundation
import Vapor

/// Errors surfaced by `configureDatabase(application:)`.
enum DatabaseError: Error, LocalizedError {
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

/// Registers the in-memory SQLite database, adds every migration, and runs them.
///
/// Storage is in-memory, so all data is discarded when the process exits.
///
/// - Throws: `DatabaseError.migrationFailed` or `DatabaseError.configurationFailed`.
func configureDatabase(application: Application) async throws {
    do {
        application.databases.use(.sqlite(.memory), as: .sqlite)

        application.migrations.add([
            Migrations.CreateDepartments(),
            Migrations.CreateEmployees()
        ])

        try await application.autoMigrate()
    } catch {
        // `autoMigrate()` does not surface a typed error distinguishing migration failure from
        // configuration failure, so the message is matched instead. This is fragile: any change
        // to the wording upstream, or a localized description, silently reclassifies the error
        // as `.configurationFailed`.
        let errorMessage = error.localizedDescription
        if errorMessage.contains("migration") || errorMessage.contains("Migration") {
            throw DatabaseError.migrationFailed(errorMessage)
        } else {
            throw DatabaseError.configurationFailed(errorMessage)
        }
    }
}
