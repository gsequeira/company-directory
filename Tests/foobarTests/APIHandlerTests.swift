import Fluent
import FluentSQLiteDriver
import Foundation
import OpenAPIVapor
import Testing
import Vapor
import VaporTesting

@testable import foobar

@Suite("API Handler Integration Tests")
struct APIHandlerIntegrationTests {

    @Test("POST /api/departments creates a new department successfully")
    func testCreateDepartmentSuccess() async throws {
        try await TestHelpers.withApplication { application in
            let createRequest = Components.Schemas.CreateDepartmentRequest(
                name: "Customer Support"
            )

            let response = try await application.sendRequest(.POST, "/api/departments", body: createRequest)

            #expect(response.status == .created)
            #expect(response.headers.contentType == .json)

            let createdDepartment = try response.content.decode(Components.Schemas.Department.self)
            #expect(createdDepartment.name == "Customer Support")
            #expect(createdDepartment.id > 0)
        }
    }

    @Test("POST /api/departments returns conflict for duplicate names")
    func testCreateDepartmentDuplicateName() async throws {
        try await TestHelpers.withApplication { application in
            let createRequest = Components.Schemas.CreateDepartmentRequest(
                name: "Duplicate Department"
            )

            // Create the first department
            _ = try await application.sendRequest(.POST, "/api/departments", body: createRequest)

            // Attempt to create a duplicate department
            let duplicateResponse = try await application.sendRequest(.POST, "/api/departments", body: createRequest)

            #expect(duplicateResponse.status == .conflict)
            #expect(duplicateResponse.headers.contentType == .json)

            let conflictError = try duplicateResponse.content.decode(Components.Schemas.ConflictError.self)
            #expect(conflictError.error == true)
            #expect(conflictError.reason.contains("Duplicate Department"))
        }
    }
}
