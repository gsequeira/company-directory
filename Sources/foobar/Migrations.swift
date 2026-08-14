import Fluent

enum Migrations {
    struct CreateDepartments: AsyncMigration {
        func prepare(on database: any Database) async throws {
            try await database.schema(Models.Department.schema)
                        .field("id", .int32, .identifier(auto: true))
                        .field("name", .string, .required)
                        .field("inserted_at", .datetime)
                        .field("updated_at", .datetime)
                        // Load-bearing for correctness, not just data hygiene: the duplicate-name
                        // check in APIHandler.createDepartment is a read followed by a write, so
                        // concurrent requests can both pass it. This constraint is what makes the
                        // second insert fail. Dropping it turns that check into a race.
                        .unique(on: "name")
                        .create()
        }

        func revert(on database: any Database) async throws {
            try await database
                        .schema(Models.Department.schema)
                        .delete()
        }
    }

    struct CreateEmployees: AsyncMigration {
        func prepare(on database: any Database) async throws {
            try await database.schema(Models.Employee.schema)
                .field("id", .int32, .identifier(auto: true))
                .field("first_name", .string, .required)
                .field("last_name", .string, .required)
                .field("inserted_at", .datetime)
                .field("updated_at", .datetime)
                .create()
        }

        func revert(on database: any Database) async throws {
            try await database
                .schema(Models.Employee.schema)
                .delete()
        }
    }
}
