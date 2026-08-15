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
        let departments = try await Models.Department.query(on: database).all()

        let departmentComponents = try departments.map(Components.Schemas.Department.init)

        let departmentList = Components.Schemas.DepartmentList(departments: departmentComponents)

        return .ok(.init(body: .json(departmentList)))
    }

    func createDepartment(_ input: Operations.CreateDepartment.Input) async throws -> Operations.CreateDepartment.Output {
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
                    reason: "A department with the name '\(createRequest.name)' already exists"
                )
                return .conflict(.init(body: .json(conflictResponse)))
            }

            let newDepartment = Models.Department()
            newDepartment.name = createRequest.name

            do {
                try await newDepartment.save(on: database)
            } catch let error as any FluentKit.DatabaseError where error.isConstraintFailure {
                // The pre-check lost the race: another request inserted this name between the
                // query above and this save, and the unique index rejected the second insert.
                // Without this, the loser of that race gets a 500 for a plain conflict.
                //
                // `isConstraintFailure` covers every constraint type, which is precise enough
                // only because uniqueness is currently the sole constraint on this table. The
                // Phase 2 foreign key will break that assumption — see the note in
                // Docs/MIGRATIONS.md.
                return .conflict(
                    .init(
                        body: .json(
                            Components.Schemas.ConflictError(
                                error: true,
                                reason: "A department with the name '\(createRequest.name)' already exists"
                            )
                        )
                    )
                )
            }

            let departmentResponse = try Components.Schemas.Department(newDepartment)

            return .created(.init(body: .json(departmentResponse)))
        }
    }

    func getDepartmentDetail(_ input: Operations.GetDepartmentDetail.Input) async throws -> Operations.GetDepartmentDetail.Output {
        let departmentId = input.path.departmentId

        guard let department = try await Models.Department.find(departmentId, on: database) else {
            return .notFound(.init())
        }

        let departmentResponse = try Components.Schemas.Department(department)

        return .ok(.init(body: .json(departmentResponse)))
    }

    func updateDepartment(_ input: Operations.UpdateDepartment.Input) async throws -> Operations.UpdateDepartment.Output {
        let departmentId = input.path.departmentId

        switch input.body {
        case .json(let updateRequest):
            guard let existingDepartment = try await Models.Department.find(departmentId, on: database) else {
                return .notFound(.init())
            }

            if try await Models.Department.query(on: database)
                .filter(\.$name == updateRequest.name)
                .filter(\.$id != (try existingDepartment.requireID()))
                .first() != nil
            {
                let conflictResponse = Components.Schemas.ConflictError(
                    error: true,
                    reason: "A department with the name '\(updateRequest.name)' already exists"
                )
                return .conflict(.init(body: .json(conflictResponse)))
            }

            existingDepartment.name = updateRequest.name

            do {
                try await existingDepartment.save(on: database)
            } catch let error as any FluentKit.DatabaseError where error.isConstraintFailure {
                // Same race as createDepartment, reached by renaming onto a name another
                // request took in the meantime.
                return .conflict(
                    .init(
                        body: .json(
                            Components.Schemas.ConflictError(
                                error: true,
                                reason: "A department with the name '\(updateRequest.name)' already exists"
                            )
                        )
                    )
                )
            }

            let departmentResponse = try Components.Schemas.Department(existingDepartment)

            return .ok(.init(body: .json(departmentResponse)))
        }
    }

    func deleteDepartment(_ input: Operations.DeleteDepartment.Input) async throws -> Operations.DeleteDepartment.Output {
        let departmentId = input.path.departmentId

        guard let existingDepartment = try await Models.Department.find(departmentId, on: database) else {
            return .notFound(.init())
        }

        try await existingDepartment.delete(on: database)

        return .noContent(.init())
    }

    func listEmployees(_ input: Operations.ListEmployees.Input) async throws -> Operations.ListEmployees.Output {
        let employees = try await Models.Employee.query(on: database).all()

        let employeeComponents = try employees.map(Components.Schemas.Employee.init)

        let employeeList = Components.Schemas.EmployeeList(employees: employeeComponents)

        return .ok(.init(body: .json(employeeList)))
    }

    func createEmployee(_ input: Operations.CreateEmployee.Input) async throws -> Operations.CreateEmployee.Output {
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

            do {
                try await newEmployee.save(on: database)
            } catch let error as any FluentKit.DatabaseError where error.isConstraintFailure {
                // See createDepartment: the pre-check races, and the unique constraint added
                // by Migrations.AddEmployeeNameUniqueness is what catches the loser.
                return .conflict(
                    .init(
                        body: .json(
                            Components.Schemas.ConflictError(
                                error: true,
                                reason:
                                    "An employee named '\(createRequest.firstName) \(createRequest.lastName)' already exists"
                            )
                        )
                    )
                )
            }

            let employeeResponse = try Components.Schemas.Employee(newEmployee)

            return .created(.init(body: .json(employeeResponse)))
        }
    }
}
