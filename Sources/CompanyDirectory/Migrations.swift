import Fluent
// `SQLDatabase` and `raw(_:)` come from SQLKit, which is not a declared dependency of this target
// and does not need to be: FluentPostgresDriver re-exports it. `RequireEmployeeDepartment` is the
// only migration that needs to drop below Fluent's schema builder — see the note there.
import FluentPostgresDriver

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

    /// Step 2 of 3: give every existing employee a department (#18, #20).
    ///
    /// `RequireEmployeeDepartment` cannot apply `NOT NULL` while any row holds `NULL`, so those
    /// rows have to be given a value first. This is the step that only matters against real data:
    /// the test suite reverts migrations between tests and therefore always runs this against an
    /// empty table, where it does nothing at all. `Docs/MIGRATIONS.md` records why that blind spot
    /// makes a populated development database the only honest place to prove this works.
    ///
    /// Employees with no department are assigned to one named `Unassigned`, created here if it is
    /// not already present. Inventing a placeholder is a real decision rather than an obvious one:
    /// the alternative is refusing to migrate until a human assigns each row, which is safer for
    /// data and useless for a project whose whole point is that the migration runs unattended at
    /// startup. The placeholder is visible in the API, so nothing is hidden — an employee whose
    /// department reads `Unassigned` is a row somebody still needs to look at.
    struct BackfillEmployeeDepartment: AsyncMigration {
        static let placeholderName = "Unassigned"

        func prepare(on database: any Database) async throws {
            let orphaned = try await Models.Employee.query(on: database)
                .filter(\.$department.$id == .null)
                .count()

            guard orphaned > 0 else { return }

            let existing = try await Models.Department.query(on: database)
                .filter(\.$name == Self.placeholderName)
                .first()

            let placeholder: Models.Department
            if let existing {
                placeholder = existing
            } else {
                placeholder = Models.Department(name: Self.placeholderName)
                try await placeholder.save(on: database)
            }

            try await Models.Employee.query(on: database)
                .filter(\.$department.$id == .null)
                .set(\.$department.$id, to: try placeholder.requireID())
                .update()
        }

        /// Deliberately does nothing.
        ///
        /// A revert cannot know which rows this filled in, so restoring `NULL` would blank
        /// departments that were set legitimately afterwards. The placeholder department is left
        /// in place for the same reason — deleting it would fail against any employee still
        /// pointing at it. Reverting step 3 is what makes the column nullable again; this step
        /// has nothing to undo that is safe to undo.
        func revert(on database: any Database) async throws {}
    }

    /// Step 3 of 3: make the department mandatory at the database level (#18, #20).
    ///
    /// **This one needs raw SQL.** Fluent's `DatabaseSchema.FieldUpdate` offers exactly two
    /// cases, `.dataType` and `.custom`, so the schema builder can change a column's *type* but
    /// cannot add a constraint to a column that already exists. `.field(...)` with `.required`
    /// would emit `ADD COLUMN`, which fails because the column is already there.
    ///
    /// `SQLKit` arrives through `FluentPostgresDriver`'s `@_exported` imports, so reaching for it
    /// costs no new dependency — but it does cost portability, which is why the cast is explicit
    /// and fails loudly rather than silently skipping on a database that is not SQL-backed.
    struct RequireEmployeeDepartment: AsyncMigration {
        private func sql(_ database: any Database) throws -> any SQLDatabase {
            guard let sql = database as? any SQLDatabase else {
                throw DatabaseSetupError.migrationFailed(
                    "RequireEmployeeDepartment needs a SQL database; got \(type(of: database))"
                )
            }
            return sql
        }

        func prepare(on database: any Database) async throws {
            try await sql(database).raw(
                "ALTER TABLE employees ALTER COLUMN department_id SET NOT NULL"
            ).run()
        }

        func revert(on database: any Database) async throws {
            try await sql(database).raw(
                "ALTER TABLE employees ALTER COLUMN department_id DROP NOT NULL"
            ).run()
        }
    }
}
