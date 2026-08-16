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

    @Test("PATCH /api/departments/{departmentId} returns not found for non-existent department")
    func testUpdateDepartmentNotFound() async throws {
        try await TestHelpers.withApplication { application in
            let updateRequest = Components.Schemas.UpdateDepartmentRequest(name: "Nowhere")
            let response = try await application.sendRequest(.PATCH, "/api/departments/999",
                body: updateRequest)

            #expect(response.status == .notFound)

            // Same reasoning as getDepartmentDetail's 404: an empty body proves the request
            // reached updateDepartment rather than falling through the router.
            #expect(response.body.readableBytes == 0)
        }
    }

    @Test("PATCH /api/departments/{departmentId} returns conflict when renaming onto a taken name")
    func testUpdateDepartmentDuplicateName() async throws {
        try await TestHelpers.withApplication { application in
            let existingName = "Engineering"

            let firstResponse = try await application.sendRequest(.POST, "/api/departments",
                body: Components.Schemas.CreateDepartmentRequest(name: existingName))
            try #require(firstResponse.status == .created)

            let secondResponse = try await application.sendRequest(.POST, "/api/departments",
                body: Components.Schemas.CreateDepartmentRequest(name: "Customer Support"))
            try #require(secondResponse.status == .created)
            let secondDepartment = try secondResponse.content.decode(Components.Schemas.Department.self)

            // Rename the second department onto the first one's name.
            let updateResponse = try await application.sendRequest(
                .PATCH, "/api/departments/\(secondDepartment.id)",
                body: Components.Schemas.UpdateDepartmentRequest(name: existingName))

            #expect(updateResponse.status == .conflict)
            #expect(updateResponse.headers.contentType == .json)

            let conflictError = try updateResponse.content.decode(Components.Schemas.ConflictError.self)
            #expect(conflictError.error == true)
            #expect(conflictError.reason.contains(existingName))
        }
    }

    @Test("PATCH /api/departments/{departmentId} allows a department to keep its own name")
    func testUpdateDepartmentSelfRename() async throws {
        try await TestHelpers.withApplication { application in
            let name = "Research and Development"

            let createResponse = try await application.sendRequest(.POST, "/api/departments",
                body: Components.Schemas.CreateDepartmentRequest(name: name))
            try #require(createResponse.status == .created)
            let createdDepartment = try createResponse.content.decode(Components.Schemas.Department.self)

            // Renaming a department to the name it already has must not conflict with itself.
            // This is the only test holding the `.filter(\.$id != …)` line in updateDepartment
            // in place — without it, that line can be deleted and the whole suite still passes.
            let updateResponse = try await application.sendRequest(
                .PATCH, "/api/departments/\(createdDepartment.id)",
                body: Components.Schemas.UpdateDepartmentRequest(name: name))

            #expect(updateResponse.status == .ok)
            #expect(updateResponse.headers.contentType == .json)

            let updatedDepartment = try updateResponse.content.decode(Components.Schemas.Department.self)
            #expect(updatedDepartment.id == createdDepartment.id)
            #expect(updatedDepartment.name == name)
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

    @Test("GET /api/employees/{employeeId} returns specific employee when it exists")
    func testGetEmployeeDetailSuccess() async throws {
        try await TestHelpers.withApplication { application in
            let createResponse = try await application.sendRequest(.POST, "/api/employees",
                body: Components.Schemas.CreateEmployeeRequest(firstName: "Ada", lastName: "Lovelace"))
            try #require(createResponse.status == .created)
            let createdEmployee = try createResponse.content.decode(Components.Schemas.Employee.self)

            let response = try await application.sendRequest(.GET, "/api/employees/\(createdEmployee.id)")

            #expect(response.status == .ok)
            #expect(response.headers.contentType == .json)

            let fetchedEmployee = try response.content.decode(Components.Schemas.Employee.self)
            #expect(fetchedEmployee.id == createdEmployee.id)
            #expect(fetchedEmployee.firstName == "Ada")
            #expect(fetchedEmployee.lastName == "Lovelace")
        }
    }

    @Test("GET /api/employees/{employeeId} returns not found for non-existent employee")
    func testGetEmployeeDetailNotFound() async throws {
        try await TestHelpers.withApplication { application in
            let response = try await application.sendRequest(.GET, "/api/employees/999")
            #expect(response.status == .notFound)

            // An empty body proves the request reached getEmployeeDetail rather than falling
            // through the router, which would carry Vapor's {"error":true,"reason":"Not Found"}.
            #expect(response.body.readableBytes == 0)
        }
    }

    @Test("PATCH /api/employees/{employeeId} updates one field and leaves the other unchanged")
    func testUpdateEmployeePartial() async throws {
        try await TestHelpers.withApplication { application in
            let createResponse = try await application.sendRequest(.POST, "/api/employees",
                body: Components.Schemas.CreateEmployeeRequest(firstName: "Ada", lastName: "Lovelace"))
            try #require(createResponse.status == .created)
            let createdEmployee = try createResponse.content.decode(Components.Schemas.Employee.self)

            // The whole point of the PATCH decision in API-DESIGN.md §1.3: a client correcting a
            // first name should not have to know the last name.
            let updateRequest = Components.Schemas.UpdateEmployeeRequest(firstName: "Augusta")
            let response = try await application.sendRequest(.PATCH, "/api/employees/\(createdEmployee.id)",
                body: updateRequest)

            #expect(response.status == .ok)
            #expect(response.headers.contentType == .json)

            let updatedEmployee = try response.content.decode(Components.Schemas.Employee.self)
            #expect(updatedEmployee.id == createdEmployee.id)
            #expect(updatedEmployee.firstName == "Augusta")
            #expect(updatedEmployee.lastName == "Lovelace")
        }
    }

    @Test("PATCH /api/employees/{employeeId} with an empty body changes nothing")
    func testUpdateEmployeeEmptyBody() async throws {
        try await TestHelpers.withApplication { application in
            let createResponse = try await application.sendRequest(.POST, "/api/employees",
                body: Components.Schemas.CreateEmployeeRequest(firstName: "Grace", lastName: "Hopper"))
            try #require(createResponse.status == .created)
            let createdEmployee = try createResponse.content.decode(Components.Schemas.Employee.self)

            // Sent as raw bytes rather than an encoded struct, because `{}` on the wire is what a
            // client actually produces when its patch turns out to be empty. It must not conflict
            // with the employee's own row — see the `$id !=` filter in updateEmployee.
            let response = try await application.sendRequest(.PATCH, "/api/employees/\(createdEmployee.id)",
                body: Data("{}".utf8))

            #expect(response.status == .ok)

            let updatedEmployee = try response.content.decode(Components.Schemas.Employee.self)
            #expect(updatedEmployee.firstName == "Grace")
            #expect(updatedEmployee.lastName == "Hopper")
        }
    }

    @Test("PATCH /api/employees/{employeeId} returns conflict when the resulting name is taken")
    func testUpdateEmployeeDuplicateName() async throws {
        try await TestHelpers.withApplication { application in
            let firstResponse = try await application.sendRequest(.POST, "/api/employees",
                body: Components.Schemas.CreateEmployeeRequest(firstName: "Ada", lastName: "Lovelace"))
            try #require(firstResponse.status == .created)

            let secondResponse = try await application.sendRequest(.POST, "/api/employees",
                body: Components.Schemas.CreateEmployeeRequest(firstName: "Grace", lastName: "Lovelace"))
            try #require(secondResponse.status == .created)
            let secondEmployee = try secondResponse.content.decode(Components.Schemas.Employee.self)

            // Only `firstName` is sent. The check has to combine it with the *stored* last name
            // to see the collision — checking the supplied fields alone would miss it.
            let response = try await application.sendRequest(.PATCH, "/api/employees/\(secondEmployee.id)",
                body: Components.Schemas.UpdateEmployeeRequest(firstName: "Ada"))

            #expect(response.status == .conflict)
            #expect(response.headers.contentType == .json)

            let conflictError = try response.content.decode(Components.Schemas.ConflictError.self)
            #expect(conflictError.error == true)
            #expect(conflictError.reason.contains("Ada Lovelace"))
        }
    }

    @Test("PATCH /api/employees/{employeeId} returns not found for non-existent employee")
    func testUpdateEmployeeNotFound() async throws {
        try await TestHelpers.withApplication { application in
            let response = try await application.sendRequest(.PATCH, "/api/employees/999",
                body: Components.Schemas.UpdateEmployeeRequest(firstName: "Nobody"))

            #expect(response.status == .notFound)
            #expect(response.body.readableBytes == 0)
        }
    }

    @Test("DELETE /api/employees/{employeeId} deletes existing employee successfully")
    func testDeleteEmployeeSuccess() async throws {
        try await TestHelpers.withApplication { application in
            let createResponse = try await application.sendRequest(.POST, "/api/employees",
                body: Components.Schemas.CreateEmployeeRequest(firstName: "Ada", lastName: "Lovelace"))
            try #require(createResponse.status == .created)
            let createdEmployee = try createResponse.content.decode(Components.Schemas.Employee.self)

            let deleteResponse = try await application.sendRequest(.DELETE, "/api/employees/\(createdEmployee.id)")
            #expect(deleteResponse.status == .noContent)

            // Verified by reading state back through the API rather than trusting the status.
            let fetchResponse = try await application.sendRequest(.GET, "/api/employees/\(createdEmployee.id)")
            #expect(fetchResponse.status == .notFound)
        }
    }

    @Test("DELETE /api/employees/{employeeId} returns not found for non-existent employee")
    func testDeleteEmployeeNotFound() async throws {
        try await TestHelpers.withApplication { application in
            let response = try await application.sendRequest(.DELETE, "/api/employees/999")

            #expect(response.status == .notFound)
            #expect(response.body.readableBytes == 0)
        }
    }

    @Test("PATCH /api/departments/{departmentId} with an empty body changes nothing")
    func testUpdateDepartmentEmptyBody() async throws {
        try await TestHelpers.withApplication { application in
            let createResponse = try await application.sendRequest(.POST, "/api/departments",
                body: Components.Schemas.CreateDepartmentRequest(name: "Engineering"))
            try #require(createResponse.status == .created)
            let createdDepartment = try createResponse.content.decode(Components.Schemas.Department.self)

            // The department half of the same decision: `name` is now optional, and omitting it
            // must leave the column alone rather than blanking it.
            let response = try await application.sendRequest(.PATCH, "/api/departments/\(createdDepartment.id)",
                body: Data("{}".utf8))

            #expect(response.status == .ok)

            let updatedDepartment = try response.content.decode(Components.Schemas.Department.self)
            #expect(updatedDepartment.id == createdDepartment.id)
            #expect(updatedDepartment.name == "Engineering")
        }
    }
}
