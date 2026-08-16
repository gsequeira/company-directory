import Fluent
import Foundation
import Testing

@testable import CompanyDirectory

// Unit tests, not integration tests — these touch no database, so they need neither
// `TestHelpers.withApplication` nor the `.serialized` trait that the integration suite depends on.
//
// What they exist for: the conversions in SchemaConversions.swift are the single place a model's
// optional `id` is unwrapped. Before #8 that unwrap was `model.id!` in seven separate places,
// relying on an invariant — "Fluent has populated `id` by now" — that nothing stated and the
// compiler could not check. These tests state it.
@Suite("Schema conversions")
struct SchemaConversionTests {

    @Test("A persisted department converts to its response type")
    func testDepartmentConversion() throws {
        let model = Models.Department(name: "Engineering")
        model.id = 42

        let schema = try Components.Schemas.Department(model)

        #expect(schema.id == 42)
        #expect(schema.name == "Engineering")
    }

    @Test("An unsaved department throws rather than trapping")
    func testUnsavedDepartmentThrows() {
        // The model has never been saved, so `id` is nil. The old `model.id!` would have trapped
        // here — and a trap in a server aborts the process, taking every in-flight request with
        // it. Throwing means Vapor's error middleware answers 500 and the server keeps serving.
        #expect(throws: FluentError.self) {
            try Components.Schemas.Department(Models.Department(name: "Never saved"))
        }
    }

    @Test("A persisted employee converts to its response type")
    func testEmployeeConversion() throws {
        let model = Models.Employee(firstName: "Ada", lastName: "Lovelace")
        model.id = 7

        let schema = try Components.Schemas.Employee(model)

        #expect(schema.id == 7)
        #expect(schema.firstName == "Ada")
        #expect(schema.lastName == "Lovelace")
    }

    @Test("An unsaved employee throws rather than trapping")
    func testUnsavedEmployeeThrows() {
        #expect(throws: FluentError.self) {
            try Components.Schemas.Employee(Models.Employee(firstName: "Never", lastName: "Saved"))
        }
    }
}
