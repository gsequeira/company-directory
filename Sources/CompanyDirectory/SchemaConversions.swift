import Fluent
import Foundation

// Conversions from Fluent models to the generated API response types.
//
// These live on the *schema* types rather than as `toSchema()` methods on the models,
// deliberately. The API layer is allowed to know about the domain model; the model must not know
// about generated API types, or regenerating the spec starts rippling into `Models.swift`.
//
// Each one is `throws` because a model's `id` is optional until the database assigns it. Reaching
// these with a `nil` id would mean a model that was never saved — a programming error rather than
// a client error, so it surfaces as a `500` through Vapor's error middleware. That is the point:
// the previous `model.id!` **trapped**, and a trap in a server aborts the process and every
// in-flight request with it, not just the one that hit the bad model.

extension Components.Schemas.Department {
    /// Builds the response type from a persisted department.
    ///
    /// - Throws: `FluentError.idRequired` if the model has not been saved.
    init(_ model: Models.Department) throws {
        self.init(
            id: Int(try model.requireID()),
            name: model.name
        )
    }
}

extension Components.Schemas.Employee {
    /// Builds the response type from a persisted employee.
    ///
    /// - Throws: `FluentError.idRequired` if the model has not been saved.
    init(_ model: Models.Employee) throws {
        self.init(
            id: Int(try model.requireID()),
            // `$department.id` is the stored foreign key, so this reads a column that is already
            // on the fetched row. Using `model.department.id` instead would require the relation
            // to have been eager-loaded and would trap when it had not — and, once loaded per
            // employee, would be the N+1 in `Docs/FLUENT.md`.
            departmentId: model.$department.id,
            firstName: model.firstName,
            lastName: model.lastName
        )
    }
}
