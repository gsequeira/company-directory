import Fluent
import FluentSQLiteDriver
import Foundation
import Vapor

enum DatabaseError: Error, LocalizedError {
    case migrationFailed(String)
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .migrationFailed(let message):
            return "Databse migration failed: \(message)"
        case .configurationFailed(let message):
            return "Database configuration failed: \(message)"
        }
    }
}

func configureDatabase(application: Application) async throws {
    do {
        // Configure SQLite database
        application.databases.use(.sqlite(.memory), as: .sqlite)

        // Add migrations
        application.migrations.add([
            Migrations.CreatePolls()
        ])

        // Run migrations automatically
        try await application.autoMigrate()
    } catch {
        let errorMessage = error.localizedDescription
        if errorMessage.contains("migration") || errorMessage.contains("Migration") {
            throw DatabaseError.migrationFailed(errorMessage)
        } else {
            throw DatabaseError.configurationFailed(errorMessage)
        }
    }
}
