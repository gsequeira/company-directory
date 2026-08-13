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
        do {
            // Query all departmentsfrom the database
            let departments = try await Models.Department.query(on: database).all()

            // Convert database models to API response format
            let departmentComponents = departments.map { department in
                Components.Schemas.Department(id: Int(department.id!), name: department.name)
            }

            // Create paginated response
            let pageOfDepartments = Components.Schemas.PageOfDepartments(departments: departmentComponents)

            return .ok(.init(body: .json(pageOfDepartments)))
        } catch {
            throw error
        }
    }

    func createDepartment(_ input: Operations.CreateDepartment.Input) async throws -> Operations.CreateDepartment.Output {
        do {
            switch input.body {
            case .json(let createRequest):
                // Check for existing department with the same name
                if try await Models.Department.query(on: database)
                    .filter(\.$name == createRequest.name)
                    .first() != nil
                {
                    let conflictResponse = Components.Schemas.ConflictError(
                        error: true,
                        reason: "A department with the name '\(createRequest.name) already exists"
                    )
                    return .conflict(.init(body: .json(conflictResponse)))
                }

                // Create new department model
                let newDepartment = Models.Department()
                newDepartment.name = createRequest.name
                newDepartment.updatedAt = Date()

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

    func getDepartmentDetail(_ input: Operations.GetDepartmentDetail.Input) async throws -> Operations.GetDepartmentDetail.Output {
        do {
             let departmentId = input.path.departmentId

             // Find the department by ID in the database
             guard let department = try await Models.Department.find(Int32(departmentId), on: database) else {
                return .notFound(.init())
             }

             // Convert database model to API response format
             let departmentResponse = Components.Schemas.Department(
                id: Int(department.id!),
                name: department.name
            )

            return .ok(.init(body: .json(departmentResponse)))
        } catch {
            throw error
        }
    }

    func updateDepartment(_ input: Operations.UpdateDepartment.Input) async throws -> Operations.UpdateDepartment.Output {
        do {
            let departmentId = input.path.departmentId

            switch input.body {
            case .json(let updateRequest):
                // Find the existing department
                guard let existingDepartment = try await Models.Department.find(Int32(departmentId), on: database) else {
                    return .notFound(.init())
                }

                // Check if another department already has this name (excluding current department)
                if try await Models.Department.query(on: database)
                    .filter(\.$name == updateRequest.name)
                    .filter(\.$id != existingDepartment.id!)
                    .first() != nil
                {
                    let conflictResponse = Components.Schemas.ConflictError(
                        error: true,
                        reason: "A department with the name '\(updateRequest.name)' already exists"
                    )
                    return .conflict(.init(body: .json(conflictResponse)))
                }

                // Update the department
                existingDepartment.name = updateRequest.name

                try await existingDepartment.save(on: database)

                // Convert to API response format
                let departmentResponse = Components.Schemas.Department(
                    id: Int(existingDepartment.id!),
                    name: existingDepartment.name
                )

                return .ok(.init(body: .json(departmentResponse)))
            }
        } catch {
            throw error
        }
    }

    func deleteDepartment(_ input: Operations.DeleteDepartment.Input) async throws -> Operations.DeleteDepartment.Output {
        do {
            let departmentid = input.path.departmentId

            // Find the existing department
            guard let existingDepartment = try await Models.Department.find(Int32(departmentid), on: database) else {
                return .notFound(.init())
            }

            // Delete the department from the database
            try await existingDepartment.delete(on: database)

            return .noContent(.init())
        } catch {
            throw error
        }
    }
}
