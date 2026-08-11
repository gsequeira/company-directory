import Fluent
import Foundation

enum Models {
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

        init() { }

        init(name: String) {
            self.name = name
        }
    }
}
