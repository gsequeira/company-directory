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

    /// Adds the unique constraint that `createEmployee`'s 409 has always assumed.
    ///
    /// This is a new migration rather than an edit to `CreateEmployees`. Fluent records every
    /// applied migration in `_fluent_migrations` and skips the ones already listed there, so
    /// editing `CreateEmployees` would change nothing on any database where it has already run —
    /// including this one. Once a migration has been applied anywhere it is history: append,
    /// never amend.
    ///
    /// Note `.update()` rather than `.create()`: the table already exists, and this alters it.
    struct AddEmployeeNameUniqueness: AsyncMigration {
        func prepare(on database: any Database) async throws {
            try await database.schema(Models.Employee.schema)
                .unique(on: "first_name", "last_name")
                .update()
        }

        func revert(on database: any Database) async throws {
            try await database.schema(Models.Employee.schema)
                .deleteUnique(on: "first_name", "last_name")
                .update()
        }
    }

    /// Step 1 of 3 in giving every employee a department (#18, #20).
    ///
    /// The column arrives **nullable**, which is the only way to add it to a table that already
    /// holds rows — every existing row would violate a `NOT NULL` constraint the moment it was
    /// applied. `Docs/MIGRATIONS.md` describes the sequence: add nullable, backfill, then
    /// constrain. `BackfillEmployeeDepartment` and `RequireEmployeeDepartment` are the other two.
    ///
    /// **The foreign key is real from the start**, even though the column is optional. That is the
    /// point of doing this step on its own: referential integrity can be proved before any code
    /// depends on it. On the SQLite stack this project started with, `.references(...)` would have
    /// been recorded and silently unenforced unless `PRAGMA foreign_keys = ON` was set per
    /// connection — see `Docs/POSTGRES.md` for why the database moved before this phase.
    ///
    /// `onDelete: .restrict` implements the decision in `Docs/API-DESIGN.md` §2.4. FluentKit
    /// defaults `onDelete` to `.noAction`, which PostgreSQL also refuses the delete on — the two
    /// differ only in when the check fires. It is declared explicitly so the intent reads from the
    /// migration rather than being inferred from a default.
    struct AddEmployeeDepartment: AsyncMigration {
        func prepare(on database: any Database) async throws {
            try await database.schema(Models.Employee.schema)
                .field(
                    "department_id", .int32,
                    .references(Models.Department.schema, "id", onDelete: .restrict)
                )
                .update()
        }

        func revert(on database: any Database) async throws {
            try await database.schema(Models.Employee.schema)
                .deleteField("department_id")
                .update()
        }
    }
}
