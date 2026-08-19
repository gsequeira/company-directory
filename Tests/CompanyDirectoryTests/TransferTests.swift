import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import CompanyDirectory

// An extension of the existing suite rather than a suite of its own. `.serialized` does not
// serialize one suite against another, and a second `@Suite` over the same database makes both
// fail as each one's `autoRevert()` drops the other's tables mid-test. See `Docs/TESTING.md`.
extension APIHandlerIntegrationTests {

    // Tests for POST /api/departments/{departmentId}/transfer

    @Test("POST /api/departments/{id}/transfer moves every employee and reports the count")
    func testTransferMovesEveryEmployee() async throws {
        try await TestHelpers.withApplication { application in
            let sourceId = try await TestHelpers.createDepartment(application, named: "Engineering")
            let targetId = try await TestHelpers.createDepartment(application, named: "Platform")

            _ = try await createEmployee(application, "Ada", "Lovelace", in: sourceId)
            _ = try await createEmployee(application, "Grace", "Hopper", in: sourceId)

            let response = try await application.sendRequest(
                .POST, "/api/departments/\(sourceId)/transfer",
                body: Components.Schemas.TransferEmployeesRequest(targetDepartmentId: targetId))

            #expect(response.status == .ok)
            #expect(response.headers.contentType == .json)

            let result = try response.content.decode(Components.Schemas.TransferResult.self)
            #expect(result.transferred == 2)
            #expect(result.sourceDeleted == false)

            let employees = try await listEmployees(application)
            #expect(employees.allSatisfy { $0.departmentId == targetId })
        }
    }

    @Test("Transferring an empty department reports zero and is not an error")
    func testTransferFromEmptyDepartment() async throws {
        try await TestHelpers.withApplication { application in
            let sourceId = try await TestHelpers.createDepartment(application, named: "Engineering")
            let targetId = try await TestHelpers.createDepartment(application, named: "Platform")

            let response = try await application.sendRequest(
                .POST, "/api/departments/\(sourceId)/transfer",
                body: Components.Schemas.TransferEmployeesRequest(targetDepartmentId: targetId))

            #expect(response.status == .ok)

            let result = try response.content.decode(Components.Schemas.TransferResult.self)
            #expect(result.transferred == 0)
        }
    }

    @Test("deleteSourceAfterTransfer removes the source department")
    func testTransferDeletesSourceWhenAsked() async throws {
        try await TestHelpers.withApplication { application in
            let sourceId = try await TestHelpers.createDepartment(application, named: "Engineering")
            let targetId = try await TestHelpers.createDepartment(application, named: "Platform")

            _ = try await createEmployee(application, "Ada", "Lovelace", in: sourceId)

            let response = try await application.sendRequest(
                .POST, "/api/departments/\(sourceId)/transfer",
                body: Components.Schemas.TransferEmployeesRequest(
                    targetDepartmentId: targetId,
                    deleteSourceAfterTransfer: true
                ))

            #expect(response.status == .ok)

            let result = try response.content.decode(Components.Schemas.TransferResult.self)
            #expect(result.transferred == 1)
            #expect(result.sourceDeleted == true)

            let sourceLookup = try await application.sendRequest(.GET, "/api/departments/\(sourceId)")
            #expect(sourceLookup.status == .notFound)
        }
    }

    @Test("Without the flag the source department survives the transfer")
    func testTransferKeepsSourceByDefault() async throws {
        try await TestHelpers.withApplication { application in
            let sourceId = try await TestHelpers.createDepartment(application, named: "Engineering")
            let targetId = try await TestHelpers.createDepartment(application, named: "Platform")

            _ = try await createEmployee(application, "Ada", "Lovelace", in: sourceId)

            _ = try await application.sendRequest(
                .POST, "/api/departments/\(sourceId)/transfer",
                body: Components.Schemas.TransferEmployeesRequest(
                    targetDepartmentId: targetId,
                    deleteSourceAfterTransfer: false
                ))

            let sourceLookup = try await application.sendRequest(.GET, "/api/departments/\(sourceId)")
            #expect(sourceLookup.status == .ok)
        }
    }

    @Test("Transfer returns 404 when the source department does not exist")
    func testTransferSourceNotFound() async throws {
        try await TestHelpers.withApplication { application in
            let targetId = try await TestHelpers.createDepartment(application, named: "Platform")

            let response = try await application.sendRequest(
                .POST, "/api/departments/99999/transfer",
                body: Components.Schemas.TransferEmployeesRequest(targetDepartmentId: targetId))

            // Empty body, because the source is the resource in the path. API-DESIGN.md §3.3.
            #expect(response.status == .notFound)
            #expect(response.body.readableBytes == 0)
        }
    }

    @Test("Transfer returns 422 when the target department does not exist")
    func testTransferTargetNotFound() async throws {
        try await TestHelpers.withApplication { application in
            let sourceId = try await TestHelpers.createDepartment(application, named: "Engineering")

            let response = try await application.sendRequest(
                .POST, "/api/departments/\(sourceId)/transfer",
                body: Components.Schemas.TransferEmployeesRequest(targetDepartmentId: 99999))

            #expect(response.status == .unprocessableEntity)

            let referenceError = try response.content.decode(Components.Schemas.ReferenceError.self)
            #expect(referenceError.error == true)
            #expect(referenceError.reason.contains("99999"))
        }
    }

    @Test("Transfer returns 422 when the target is the source")
    func testTransferIntoItself() async throws {
        try await TestHelpers.withApplication { application in
            let sourceId = try await TestHelpers.createDepartment(application, named: "Engineering")

            let response = try await application.sendRequest(
                .POST, "/api/departments/\(sourceId)/transfer",
                body: Components.Schemas.TransferEmployeesRequest(targetDepartmentId: sourceId))

            #expect(response.status == .unprocessableEntity)

            let referenceError = try response.content.decode(Components.Schemas.ReferenceError.self)
            #expect(referenceError.reason.contains("itself"))
        }
    }

    /// The test the transaction exists for.
    ///
    /// The happy path above passes whether or not the two writes share a transaction, because
    /// writing `query(on: database)` inside the closure instead of `query(on: db)` produces a
    /// transaction wrapping nothing and no error of any kind. Only a failure between the two
    /// writes tells them apart.
    ///
    /// `beforeSourceDelete` supplies that failure without simulating one: it assigns an employee
    /// to the source department on a different connection and commits, which is exactly the race
    /// a client loses in production. The `.restrict` foreign key then refuses the delete, and the
    /// assertion is that **nobody moved**, not merely that the response was a `409`.
    @Test("A delete that fails rolls the whole transfer back")
    func testTransferRollsBackWhenTheDeleteFails() async throws {
        let assignAnEmployeeToTheSource: @Sendable (Application) async throws -> Void = { application in
            let source = try await Models.Department.query(on: application.db)
                .filter(\.$name == "Engineering")
                .first()

            if let source {
                let intruder = try Models.Employee(
                    firstName: "Late",
                    lastName: "Arrival",
                    departmentID: source.requireID()
                )

                try await intruder.save(on: application.db)
            }
        }

        try await TestHelpers.withApplication(beforeSourceDelete: assignAnEmployeeToTheSource) { application in
            let sourceId = try await TestHelpers.createDepartment(application, named: "Engineering")
            let targetId = try await TestHelpers.createDepartment(application, named: "Platform")

            _ = try await createEmployee(application, "Ada", "Lovelace", in: sourceId)
            _ = try await createEmployee(application, "Grace", "Hopper", in: sourceId)

            let response = try await application.sendRequest(
                .POST, "/api/departments/\(sourceId)/transfer",
                body: Components.Schemas.TransferEmployeesRequest(
                    targetDepartmentId: targetId,
                    deleteSourceAfterTransfer: true
                ))

            #expect(response.status == .conflict)

            let conflictError = try response.content.decode(Components.Schemas.ConflictError.self)
            #expect(conflictError.reason.contains("Engineering"))

            // The rollback itself. Without the transaction, the two original employees would be in
            // the target and only the intruder would remain behind.
            let employees = try await listEmployees(application)
            #expect(employees.filter { $0.departmentId == targetId }.isEmpty)
            #expect(employees.filter { $0.departmentId == sourceId }.count == 3)

            let sourceLookup = try await application.sendRequest(.GET, "/api/departments/\(sourceId)")
            #expect(sourceLookup.status == .ok)
        }
    }
}

/// Creates an employee through the API rather than by inserting a model, for the same reason
/// `TestHelpers.createDepartment` does: a regression in `createEmployee` should fail these tests
/// loudly instead of leaving them passing against data no client could have produced.
private func createEmployee(
    _ application: Application,
    _ firstName: String,
    _ lastName: String,
    in departmentId: Int32
) async throws -> Int32 {
    let response = try await application.sendRequest(
        .POST, "/api/employees",
        body: Components.Schemas.CreateEmployeeRequest(
            departmentId: departmentId,
            firstName: firstName,
            lastName: lastName
        ))

    try #require(response.status == .created)

    let employee = try response.content.decode(Components.Schemas.Employee.self)

    return Int32(employee.id)
}

private func listEmployees(_ application: Application) async throws -> [Components.Schemas.Employee] {
    let response = try await application.sendRequest(.GET, "/api/employees")

    try #require(response.status == .ok)

    return try response.content.decode(Components.Schemas.EmployeeList.self).employees
}
