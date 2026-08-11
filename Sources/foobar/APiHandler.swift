import Foundation
import OpenAPIRuntime
import OpenAPIVapor
import Vapor

struct APIHandler: APIProtocol {
    func listDepartments(_ input: Operations.ListDepartments.Input) async throws -> Operations.ListDepartments.Output {
        // Create an empty list of departments for now
        let emptyDepartments: [Components.Schemas.Department] = []
        let pageOfDepartments = Components.Schemas.PageOfDepartments(departments: emptyDepartments)

        return .ok(.init(body: .json(pageOfDepartments)))
    }
}
