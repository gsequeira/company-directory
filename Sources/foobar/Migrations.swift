import Fluent

enum Migrations {
    struct CreatePolls: AsyncMigration {
        func prepare(on database: any Database) async throws {
            try await database.schema(Models.Department.schema)
                        .field("id", .int32, .identifier(auto: true))
                        .field("name", .string, .required)
                        .field("inserted_at", .datetime)
                        .field("updated_at", .datetime)
                        .unique(on: "name")
                        .create()
        }

        func revert(on database: any Database) async throws {
            try await database
                        .schema(Models.Department.schema)
                        .delete()
        }
    }
}
