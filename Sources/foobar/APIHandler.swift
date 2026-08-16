import Fluent
import Foundation
import OpenAPIRuntime
import OpenAPIVapor
import Vapor

/// Implements `APIProtocol`, the protocol generated from `openapi.yaml`. Every route is served
/// under the `/api` base path declared by the spec's `servers` entry.
///
/// Each handler below carries its route and its declared responses, so the contract is visible
/// without opening the spec. **`openapi.yaml` remains the source of truth** — these comments
/// restate it for the reader, and must be updated when a declaration changes.
///
/// Two things are true of every handler and are therefore not repeated on each one:
///
/// - **Malformed input returns `500`, not `400`.** `swift-openapi-vapor` surfaces request-decoding
///   failures as unhandled errors. `500` is declared nowhere, so this breaks the contract on all
///   seven operations. Tracked by #2; see `Docs/API-COVERAGE.md`.
/// - **The two `401` declarations are unreachable.** No authentication exists anywhere in the
///   project, so no code path can produce one. Tracked by #11.
struct APIHandler: APIProtocol {
    let database: Database
    init(database: Database) {
        self.database = database
    }

    /// `GET /api/departments`
    ///
    /// - `200` — every department, in no guaranteed order (#3).
    func listDepartments(_ input: Operations.ListDepartments.Input) async throws -> Operations.ListDepartments.Output {
        let departments = try await Models.Department.query(on: database).all()

        let departmentComponents = try departments.map(Components.Schemas.Department.init)

        let departmentList = Components.Schemas.DepartmentList(departments: departmentComponents)

        return .ok(.init(body: .json(departmentList)))
    }

    /// `POST /api/departments`
    ///
    /// - `201` — the created department.
    /// - `401` — declared by the spec, unreachable in practice (#11).
    /// - `409` — a department already holds that name. Returned from two places: the pre-check
    ///   below, and the `catch` that handles losing the race to another request.
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

    /// `GET /api/departments/{departmentId}`
    ///
    /// - `200` — the department.
    /// - `404` — no department has that id. Sent with an empty body, which is what distinguishes
    ///   it from a routing `404`.
    func getDepartmentDetail(_ input: Operations.GetDepartmentDetail.Input) async throws -> Operations.GetDepartmentDetail.Output {
        let departmentId = input.path.departmentId

        guard let department = try await Models.Department.find(departmentId, on: database) else {
            return .notFound(.init())
        }

        let departmentResponse = try Components.Schemas.Department(department)

        return .ok(.init(body: .json(departmentResponse)))
    }

    /// `PATCH /api/departments/{departmentId}`
    ///
    /// - `200` — the updated department. Also the answer when a department is renamed to the name
    ///   it already has, which is what the `$id !=` filter below exists for.
    /// - `404` — no department has that id.
    /// - `409` — another department already holds that name.
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

    /// `DELETE /api/departments/{departmentId}`
    ///
    /// - `204` — deleted, no body.
    /// - `404` — no department has that id.
    ///
    /// What happens to a department's employees is undecided until Phase 2 gives them a
    /// relationship (#19).
    func deleteDepartment(_ input: Operations.DeleteDepartment.Input) async throws -> Operations.DeleteDepartment.Output {
        let departmentId = input.path.departmentId

        guard let existingDepartment = try await Models.Department.find(departmentId, on: database) else {
            return .notFound(.init())
        }

        try await existingDepartment.delete(on: database)

        return .noContent(.init())
    }

    /// `GET /api/employees`
    ///
    /// - `200` — every employee, in no guaranteed order (#3).
    func listEmployees(_ input: Operations.ListEmployees.Input) async throws -> Operations.ListEmployees.Output {
        let employees = try await Models.Employee.query(on: database).all()

        let employeeComponents = try employees.map(Components.Schemas.Employee.init)

        let employeeList = Components.Schemas.EmployeeList(employees: employeeComponents)

        return .ok(.init(body: .json(employeeList)))
    }

    /// `POST /api/employees`
    ///
    /// - `201` — the created employee.
    /// - `401` — declared by the spec, unreachable in practice (#11).
    /// - `409` — an employee already has that first and last name, backed by the unique constraint
    ///   from `Migrations.AddEmployeeNameUniqueness`. Whether names *should* be unique is a
    ///   modelling limitation kept deliberately; see `Docs/API-DESIGN.md` §1.2 and #25.
    ///
    /// There is no `GET`, `PATCH` or `DELETE` for a single employee yet — the resource is
    /// write-once until #9 adds `/employees/{employeeId}`.
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
