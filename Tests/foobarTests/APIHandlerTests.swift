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
}
