import Fluent
import Foundation
import OpenAPIRuntime
import OpenAPIVapor
import Vapor

struct APIHandler: APIProtocol {
    let database: Database
    init(database: Database) {
        self.database = database
    }

    func listDepartments(_ input: Operations.ListDepartments.Input) async throws -> Operations.ListDepartments.Output {
        // Create an empty list of departments for now
        let emptyDepartments: [Components.Schemas.Department] = []
        let pageOfDepartments = Components.Schemas.PageOfDepartments(departments: emptyDepartments)

        return .ok(.init(body: .json(pageOfDepartments)))
    }

    func createDepartment(_ input: Operations.CreateDepartment.Input) async throws -> Operations.CreateDepartment.Output {
        do {
            switch input.body {
            case .json(let createRequest):
                // Create new department model
                let newDepartment = Models.Department()
                newDepartment.name = createRequest.name

                // Save to database
                try await newDepartment.save(on: database)

                // Convert to API response format
                let departmentResponse = Components.Schemas.Department(
                    id: Int(newDepartment.id!),
                    name: newDepartment.name,
                )

                return .created(.init(body: .json(departmentResponse)))
            }
        } catch {
            throw error
        }
    }

    // func getDepartmentDetail(_ input: Operations.GetDepartmentDetail.Input) async throws -> Operations.GetDepartmentDetail.Output {
    //     return .notFound(.init())
    // }
    // func createDepartment(_ input: Operations.CreateDepartment.Input) async throws -> Operations.CreateDepartment.Output {
    //     .undocumented(statusCode: 500, UndocumentedPayload())
    // }
}
