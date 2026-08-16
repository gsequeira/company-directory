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

        @Timestamp(key: "inserted_at", on: .create)
        var insertedAt: Date?

        @Timestamp(key: "updated_at", on: .update)
        var updatedAt: Date?

        init() {}

        init(firstName: String, lastName: String) {
            self.firstName = firstName
            self.lastName = lastName
        }
    }
}
