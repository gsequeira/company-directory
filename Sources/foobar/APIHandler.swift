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
            let departments = try await Models.Department.query(on: database).all()

            let departmentComponents = departments.map { department in
                Components.Schemas.Department(id: Int(department.id!), name: department.name)
            }

            let departmentList = Components.Schemas.DepartmentList(departments: departmentComponents)

            return .ok(.init(body: .json(departmentList)))
        } catch {
            throw error
        }
    }

    func createDepartment(_ input: Operations.CreateDepartment.Input) async throws -> Operations.CreateDepartment.Output {
        do {
            switch input.body {
            case .json(let createRequest):
                // This check and the insert below are not atomic: two concurrent requests can
                // both find no match and both proceed. The unique index on `name` (see
                // Migrations.CreateDepartments) is what actually prevents the duplicate, by
                // failing the second insert.
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

                let newDepartment = Models.Department()
                newDepartment.name = createRequest.name

                try await newDepartment.save(on: database)

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

            guard let department = try await Models.Department.find(departmentId, on: database) else {
                return .notFound(.init())
            }

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
                guard let existingDepartment = try await Models.Department.find(departmentId, on: database) else {
                    return .notFound(.init())
                }

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

                existingDepartment.name = updateRequest.name

                try await existingDepartment.save(on: database)

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
            let departmentId = input.path.departmentId

            guard let existingDepartment = try await Models.Department.find(departmentId, on: database) else {
                return .notFound(.init())
            }

            try await existingDepartment.delete(on: database)

            return .noContent(.init())
        } catch {
            throw error
        }
    }

    func listEmployees(_ input: Operations.ListEmployees.Input) async throws -> Operations.ListEmployees.Output {
        do {
            let employees = try await Models.Employee.query(on: database).all()

            let employeeComponents = employees.map { employee in
                Components.Schemas.Employee(
                    id: Int(employee.id!),
                    firstName: employee.firstName,
                    lastName: employee.lastName
                )
            }

            let employeeList = Components.Schemas.EmployeeList(employees: employeeComponents)

            return .ok(.init(body: .json(employeeList)))
        } catch {
            throw error
        }
    }

    func createEmployee(_ input: Operations.CreateEmployee.Input) async throws -> Operations.CreateEmployee.Output {
        do {
            switch input.body {
            case .json(let createRequest):
                // Unlike departments, there is no unique index backing this check, so concurrent
                // requests can create duplicate employees. Names are not required to be unique
                // in the schema.
                if try await Models.Employee.query(on: database)
                    .filter(\.$firstName == createRequest.firstName)
                    .filter(\.$lastName == createRequest.lastName)
                    .first() != nil
                {
                    let conflictResponse = Components.Schemas.ConflictError(
                        error: true,
                        reason: "An employee named '\(createRequest.firstName) \(createRequest.lastName)' already exists"
                    )

                    return .conflict(.init(body: .json(conflictResponse)))
                }

                let newEmployee = Models.Employee()
                newEmployee.firstName = createRequest.firstName
                newEmployee.lastName = createRequest.lastName

                try await newEmployee.save(on: database)

                let employeeResponse = Components.Schemas.Employee(
                    id: Int(newEmployee.id!),
                    firstName: newEmployee.firstName,
                    lastName: newEmployee.lastName
                )

                return .created(.init(body: .json(employeeResponse)))
            }
        } catch {
            throw error
        }
    }
}
