import Fluent
import Foundation

enum Models {
    // `@unchecked Sendable` is the standard Fluent idiom: models are reference types whose
    // stored properties are mutated during hydration, so they cannot satisfy the compiler's
    // Sendable checking. It is safe here because instances never escape the request that
    // created them — each handler builds its own and converts to a value type before returning.
    final class Department: Model, @unchecked Sendable {
        static let schema = "departments"

        @ID(custom: "id", generatedBy: .database)
        var id: Int32?

        @Field(key: "name")
        var name: String

        @Timestamp(key: "inserted_at", on: .create)
        var insertedAt: Date?

        @Timestamp(key: "updated_at", on: .update)
        var updatedAt: Date?

        // The "one" side of the relationship, and not a stored property: `@Children` has no
        // column and needs no migration — it is a query waiting to be run, derived from the
        // foreign key that `Employee` owns.
        //
        // Reading it requires an explicit `.with(\.$employees)` on the query, or
        // `$employees.query(on:)`. Touching it on a model that was fetched without either traps
        // rather than returning an empty array, so the absence of employees and the failure to
        // load them are never confused.
        @Children(for: \.$department)
        var employees: [Models.Employee]

        init() {}

        init(name: String) {
            self.name = name
        }
    }

    // See the note on `Department` above for why `@unchecked Sendable` is used.
    final class Employee: Model, @unchecked Sendable {
        static let schema = "employees"

        @ID(custom: "id", generatedBy: .database)
        var id: Int32?

        @Field(key: "first_name")
        var firstName: String

        @Field(key: "last_name")
        var lastName: String

        // The "many" side owns the foreign key. `@Parent` is non-optional, which is the model
        // half of the decision in `Docs/API-DESIGN.md` §2.5 that a department is required.
        //
        // It exposes two different things, and the distinction matters for query cost:
        //
        // - `employee.$department.id` is the raw foreign key. It is always present on a fetched
        //   row and costs nothing, because it *is* a column.
        // - `employee.department` is the loaded `Department`, and is only available after
        //   `.with(\.$department)`. Reading it otherwise traps.
        //
        // Handlers here return `departmentId` and never the department's name, so nothing needs
        // eager loading and there is no N+1 to avoid yet. See `Docs/FLUENT.md` → *The N+1
        // problem* for what changes the day a response carries the name.
        @Parent(key: "department_id")
        var department: Models.Department

        @Timestamp(key: "inserted_at", on: .create)
        var insertedAt: Date?

        @Timestamp(key: "updated_at", on: .update)
        var updatedAt: Date?

        init() {}

        init(firstName: String, lastName: String, departmentID: Int32) {
            self.firstName = firstName
            self.lastName = lastName
            self.$department.id = departmentID
        }
    }
}
