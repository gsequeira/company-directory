import Fluent
import FluentPostgresDriver
import Foundation
import Testing
import Vapor

@testable import CompanyDirectory

/// Proves the `employees.department_id` foreign key is *enforced*, not merely declared.
///
/// This suite exists because of what the project moved away from. Under SQLite,
/// `.references(...)` is recorded in the schema and silently ignored unless
/// `PRAGMA foreign_keys = ON` is issued on every connection — so the insert below would have
/// succeeded and nothing would have told us. Moving to PostgreSQL before Phase 2 was done
/// specifically so that referential integrity could be relied on rather than assumed, and this
/// is the assertion that collects on it. See `Docs/POSTGRES.md`.
///
/// It works at the model layer rather than through the API on purpose: the handlers pre-check the
/// department before saving, so a request can no longer reach the constraint by the front door.
/// What is under test here is the database, not the handler.
///
/// **These are an extension of `APIHandlerIntegrationTests` rather than a suite of their own, and
/// that is load-bearing.** `.serialized` orders tests *within* a suite; it does not serialize one
/// suite against another. Declaring a second suite over the same database put two `autoRevert()`
/// calls in flight at once, and every test in both suites failed with `relation "departments" does
/// not exist` — each suite dropping the other's tables mid-test. Any future test that touches the
/// database belongs in this suite for the same reason. `Docs/TESTING.md` records it.
extension APIHandlerIntegrationTests {

    @Test("An employee referencing a department that does not exist cannot be saved")
    func testOrphanedDepartmentReferenceIsRejected() async throws {
        try await TestHelpers.withApplication { application in
            let employee = Models.Employee()
            employee.firstName = "Orphan"
            employee.lastName = "Record"
            employee.$department.id = 999_999

            await #expect(throws: (any Error).self) {
                try await employee.save(on: application.db)
            }

            // The save must leave nothing behind. A constraint that rejects the row but lets a
            // partial write through would be worse than no constraint at all.
            let survivors = try await Models.Employee.query(on: application.db).count()
            #expect(survivors == 0)
        }
    }

    @Test("A department cannot be deleted while an employee still references it")
    func testDeleteRestrictedByReferencingEmployee() async throws {
        try await TestHelpers.withApplication { application in
            let department = Models.Department(name: "Engineering")
            try await department.save(on: application.db)

            let employee = Models.Employee(
                firstName: "Ada", lastName: "Lovelace",
                departmentID: try department.requireID())
            try await employee.save(on: application.db)

            // `onDelete: .restrict` in `Migrations.AddEmployeeDepartment`. This is the backstop
            // beneath the handler's pre-check, and the thing that makes the pre-check safe to
            // lose a race: if the count and the delete interleave, the database still refuses.
            await #expect(throws: (any Error).self) {
                try await department.delete(on: application.db)
            }

            let survivors = try await Models.Department.query(on: application.db).count()
            #expect(survivors == 1)
        }
    }
}
