import Fluent
import Foundation
import OpenAPIVapor
import Testing
import Vapor
import VaporTesting

@testable import foobar

// `.serialized` is load-bearing, not a style choice. Every test shares one PostgreSQL server, and
// `TestHelpers.withApplication` reverts all migrations when each finishes — so tests running in
// parallel would drop each other's tables. See TestHelpers for the other half of the isolation.
@Suite("API Handler Integration Tests", .serialized)
struct APIHandlerIntegrationTests {

    // Tests for Department
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

    @Test("GET /api/departments returns empty list when no departments exist")
    func testListDepartmentsEmpty() async throws {
        try await TestHelpers.withApplication { application in
            let response = try await application.sendRequest(.GET, "/api/departments")

            #expect(response.status == .ok)
            #expect(response.headers.contentType == .json)

            let departmentList = try response.content.decode(Components.Schemas.DepartmentList.self)
            #expect(departmentList.departments.isEmpty)
        }
    }

    @Test("GET /api/departments returns list of departments when departments exist")
    func testListDepartmentsWithData() async throws {
        try await TestHelpers.withApplication { application in
            let department1 = Components.Schemas.CreateDepartmentRequest(name: "Engineering")
            let department2 = Components.Schemas.CreateDepartmentRequest(name: "Sales")

            // Create two departments
            _ = try await application.sendRequest(.POST, "/api/departments", body: department1)
            _ = try await application.sendRequest(.POST, "/api/departments", body: department2)

            let response = try await application.sendRequest(.GET, "/api/departments")

            #expect(response.status == .ok)
            #expect(response.headers.contentType == .json)

            let departmentList = try response.content.decode(Components.Schemas.DepartmentList.self)
            #expect(departmentList.departments.count == 2)

            let names = departmentList.departments.map { $0.name }
            #expect(names.contains("Engineering"))
            #expect(names.contains("Sales"))
        }
    }

    @Test("GET /api/departments/{departmentId} returns specific department when it exists")
    func testGetDepartmentDetailSuccess() async throws {
        try await TestHelpers.withApplication { application in
            let createRequest = Components.Schemas.CreateDepartmentRequest(name: "Information Technology")

            // Create a department first
            let createResponse = try await application.sendRequest(.POST, "/api/departments", body: createRequest)
            let createdDepartment = try createResponse.content.decode(Components.Schemas.Department.self)

            // Fetch the created department by ID
            let response = try await application.sendRequest(.GET, "/api/departments/\(createdDepartment.id)")

            #expect(response.status == .ok)
            #expect(response.headers.contentType == .json)

            let fetchedDepartment = try response.content.decode(Components.Schemas.Department.self)
            #expect(fetchedDepartment.id == createdDepartment.id)
            #expect(fetchedDepartment.name == "Information Technology")
        }
    }

    @Test("GET /api/departments/{departmentId} returns not found for non-existent department")
    func testGetDepartmentDetailNotFound() async throws {
        try await TestHelpers.withApplication { application in
            // Request a department that doesn't exist
            let response = try await application.sendRequest(.GET, "/api/departments/999")
            #expect(response.status == .notFound)

            // The handler's 404 has an empty body; a routing 404 would carry Vapor's
            // {"error":true,"reason":"Not Found"}. This is what proves the request
            // reached getDepartmentDetail rather than falling through the router.
            #expect(response.body.readableBytes == 0)
        }
    }

    @Test("PATCH /api/departments/{departmentId} updates existing department successfully")
    func testUpdateDepartmentSuccess() async throws {
        try await TestHelpers.withApplication { application in
            // Create a department
            let createRequest = Components.Schemas.CreateDepartmentRequest(name: "Customer Support")
            let createResponse = try await application.sendRequest(.POST, "/api/departments", body: createRequest)
            let createDepartment = try createResponse.content.decode(Components.Schemas.Department.self)

            // Update the department
            let updateRequest = Components.Schemas.UpdateDepartmentRequest(name: "Customer Service")
            let updatedResponse = try await application.sendRequest(.PATCH, "/api/departments/\(createDepartment.id)",
                body: updateRequest)

            #expect(updatedResponse.status == .ok)
            #expect(updatedResponse.headers.contentType == .json)

            let updatedDepartment = try updatedResponse.content.decode(Components.Schemas.Department.self)
            #expect(updatedDepartment.id == createDepartment.id)
            #expect(updatedDepartment.name == "Customer Service")
        }
    }

    @Test("DELETE /api/departments/{departmentId} deletes existing department successfully")
    func testDeleteDepartmentSuccess() async throws {
        try await TestHelpers.withApplication { application in
            // Create a department first
            let createRequest = Components.Schemas.CreateDepartmentRequest(name: "Customer Service")
            let createResponse = try await application.sendRequest(.POST, "/api/departments", body: createRequest)
            let createDepartment = try createResponse.content.decode(Components.Schemas.Department.self)

            // Delete the department
            let deleteResponse = try await application.sendRequest(.DELETE, "/api/departments/\(createDepartment.id)")
            #expect(deleteResponse.status == .noContent)

            // Verify the department is actually deleted by trying to fetch it
            let fetchResponse = try await application.sendRequest(.GET, "/api/departments/\(createDepartment.id)")
            #expect(fetchResponse.status == .notFound)
        }
    }

    @Test("DELETE /api/departments/{departmentId} returns not found for non-existent department")
    func testDeleteDepartmentNotFound() async throws {
        try await TestHelpers.withApplication { application in
            // Attempt to delete a department that doesn't exist
            let response = try await application.sendRequest(.DELETE, "/api/departments/999")
            #expect(response.status == .notFound)

            // The handler's 404 has an empty body; a routing 404 would carry Vapor's
            // {"error":true,"reason":"Not Found"}. This is what proves the request
            // reached deleteDepartment rather than falling through the router.
            #expect(response.body.readableBytes == 0)
        }
    }

    @Test("DELETE /api/departments/{departmentId} removes a department from the list")
    func testDeleteDepartmentRemovesFromList() async throws {
        try await TestHelpers.withApplication { application in
            // Create two departments
            let department1 = Components.Schemas.CreateDepartmentRequest(name: "Engineering")
            let department2 = Components.Schemas.CreateDepartmentRequest(name: "Customer Support")

            let response1 = try await application.sendRequest(.POST, "/api/departments", body: department1)
            let response2 = try await application.sendRequest(.POST, "/api/departments", body: department2)
            try #require(response1.status == .created)
            try #require(response2.status == .created)

            let createDepartment2 = try response2.content.decode(Components.Schemas.Department.self)

            // Delete the second department
            _ = try await application.sendRequest(.DELETE, "/api/departments/\(createDepartment2.id)")

            // Verify only one department remains in the list
            let listResponse = try await application.sendRequest(.GET, "/api/departments")
            let departmentList = try listResponse.content.decode(Components.Schemas.DepartmentList.self)
            #expect(departmentList.departments.count == 1)
            #expect(departmentList.departments.first?.name == "Engineering")
        }
    }

    // Tests for Employee
    @Test("POST /api/employees creates a new employee successfully")
    func testCreateEmployeeSuccess() async throws {
        try await TestHelpers.withApplication { application in
            let createRequest = Components.Schemas.CreateEmployeeRequest(
                firstName: "Jane",
                lastName: "Doe"
            )

            let response = try await application.sendRequest(.POST, "/api/employees", body: createRequest)
            #expect(response.status == .created)
            #expect(response.headers.contentType == .json)

            let createdEmployee = try response.content.decode(Components.Schemas.Employee.self)
            #expect(createdEmployee.firstName == "Jane")
            #expect(createdEmployee.lastName == "Doe")
            #expect(createdEmployee.id > 0)
        }
    }

    @Test("POST /api/employees returns conflict for duplicate employees")
    func testCreateEmployeeDuplicateName() async throws {
        try await TestHelpers.withApplication { application in
            let createRequest = Components.Schemas.CreateEmployeeRequest(
                firstName: "Jane",
                lastName: "Doe"
            )

            // Create the first employee
            _ = try await application.sendRequest(.POST, "/api/employees", body: createRequest)

            // Attempt to create a duplicate employee
            let duplicateResponse = try await application.sendRequest(.POST, "/api/employees", body: createRequest)
            #expect(duplicateResponse.status == .conflict)
            #expect(duplicateResponse.headers.contentType == .json)

            let conflictError = try duplicateResponse.content.decode(Components.Schemas.ConflictError.self)
            #expect(conflictError.error == true)
            #expect(conflictError.reason.contains("Jane Doe"))
        }
    }

    @Test("GET /api/employees returns empty list when no employee exists")
    func testListEmployeesEmpty() async throws {
        try await TestHelpers.withApplication { application in
            let response = try await application.sendRequest(.GET, "/api/employees")
            #expect(response.status == .ok)
            #expect(response.headers.contentType == .json)

            let employeeList = try response.content.decode(Components.Schemas.EmployeeList.self)
            #expect(employeeList.employees.isEmpty)
        }
    }

    @Test("GET /api/employees returns a list of employees when employees exist")
    func testListEmployeesWithData() async throws {
        try await TestHelpers.withApplication { application in
            let employee1 = Components.Schemas.CreateEmployeeRequest(firstName: "Ada", lastName: "Lovelace")
            let employee2 = Components.Schemas.CreateEmployeeRequest(firstName: "Grace", lastName: "Hopper")

            // Create two employees
            let response1 = try await application.sendRequest(.POST, "/api/employees", body: employee1)
            let response2 = try await application.sendRequest(.POST, "/api/employees", body: employee2)
            try #require(response1.status == .created)
            try #require(response2.status == .created)

            let response = try await application.sendRequest(.GET, "/api/employees")
            #expect(response.status == .ok)
            #expect(response.headers.contentType == .json)

            let employeeList = try response.content.decode(Components.Schemas.EmployeeList.self)
            #expect(employeeList.employees.count == 2)
            #expect(Set(employeeList.employees.map(\.fullName)) == ["Ada Lovelace", "Grace Hopper"])
        }
    }
}
