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
/// One thing is true of every handler and is therefore not repeated on each one:
///
/// - **Malformed input returns `500`, not `400`.** `swift-openapi-vapor` surfaces request-decoding
///   failures as unhandled errors. `500` is declared nowhere, so this breaks the contract on all
///   ten operations. Tracked by #2; see `Docs/API-COVERAGE.md` and `Docs/MIDDLEWARE.md`.
struct APIHandler: APIProtocol {
    let database: Database

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
    /// - `409` — a department already holds that name. Returned from two places: the pre-check
    ///   below, and the `catch` that handles losing the race to another request.
    func createDepartment(_ input: Operations.CreateDepartment.Input) async throws -> Operations.CreateDepartment.Output
    {
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
            } catch let error where ConstraintViolation(error) == .unique {
                // The pre-check lost the race: another request inserted this name between the
                // query above and this save, and the unique index rejected the second insert.
                // Without this, the loser of that race gets a 500 for a plain conflict.
                //
                // Narrowed from `isConstraintFailure` by #21: that covered every constraint type,
                // which stopped being precise the moment the schema held more than one kind. Any
                // other constraint failure now propagates as a 500, which is the honest answer
                // for a violation this handler did not anticipate.
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
    func getDepartmentDetail(_ input: Operations.GetDepartmentDetail.Input) async throws
        -> Operations.GetDepartmentDetail.Output
    {
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
    ///
    /// `name` is optional: a body of `{}` changes nothing and returns the department unchanged.
    /// See `Docs/API-DESIGN.md` §1.3 for why `PATCH` means partial update here.
    func updateDepartment(_ input: Operations.UpdateDepartment.Input) async throws -> Operations.UpdateDepartment.Output
    {
        let departmentId = input.path.departmentId

        switch input.body {
        case .json(let updateRequest):
            guard let existingDepartment = try await Models.Department.find(departmentId, on: database) else {
                return .notFound(.init())
            }

            // Only when a name was actually supplied. Without this guard an omitted `name` would
            // query for `nil` and, worse, blank the column below.
            if let newName = updateRequest.name {
                if try await Models.Department.query(on: database)
                    .filter(\.$name == newName)
                    .filter(\.$id != (try existingDepartment.requireID()))
                    .first() != nil
                {
                    let conflictResponse = Components.Schemas.ConflictError(
                        error: true,
                        reason: "A department with the name '\(newName)' already exists"
                    )
                    return .conflict(.init(body: .json(conflictResponse)))
                }

                existingDepartment.name = newName
            }

            do {
                try await existingDepartment.save(on: database)
            } catch let error where ConstraintViolation(error) == .unique {
                // Same race as createDepartment, reached by renaming onto a name another
                // request took in the meantime. Narrowed by #21, as above.
                return .conflict(
                    .init(
                        body: .json(
                            Components.Schemas.ConflictError(
                                error: true,
                                reason: "A department with the name '\(existingDepartment.name)' already exists"
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
    /// - `409` — employees are still assigned to it, and the reason says how many.
    ///
    /// The `409` implements the decision in `Docs/API-DESIGN.md` §2.4: deleting a department that
    /// still has employees is refused rather than cascading or nulling. It is enforced twice, and
    /// both halves are load-bearing. The count below is what produces a useful message; the
    /// `onDelete: .restrict` on the foreign key is what makes that count safe to be wrong, since
    /// a department emptied and refilled between the count and the delete is still refused by the
    /// database. Neither alone is sufficient: the constraint cannot explain itself, and the
    /// pre-check cannot be atomic.
    func deleteDepartment(_ input: Operations.DeleteDepartment.Input) async throws -> Operations.DeleteDepartment.Output
    {
        let departmentId = input.path.departmentId

        guard let existingDepartment = try await Models.Department.find(departmentId, on: database) else {
            return .notFound(.init())
        }

        let employeeCount = try await existingDepartment.$employees.query(on: database).count()

        if employeeCount > 0 {
            let conflictResponse = Components.Schemas.ConflictError(
                error: true,
                reason:
                    "Department '\(existingDepartment.name)' still has \(employeeCount) "
                    + "employee\(employeeCount == 1 ? "" : "s") assigned to it"
            )

            return .conflict(.init(body: .json(conflictResponse)))
        }

        do {
            try await existingDepartment.delete(on: database)
        } catch let error where ConstraintViolation(error) == .foreignKey {
            // The pre-check lost the race: an employee was assigned to this department between
            // the count above and the delete. The count is no longer trustworthy here, so the
            // message does not quote one.
            return .conflict(
                .init(
                    body: .json(
                        Components.Schemas.ConflictError(
                            error: true,
                            reason: "Department '\(existingDepartment.name)' still has employees assigned to it"
                        )
                    )
                )
            )
        }

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
    /// - `409` — an employee already has that first and last name, backed by the unique constraint
    ///   from `Migrations.AddEmployeeNameUniqueness`. Whether names *should* be unique is a
    ///   modelling limitation kept deliberately; see `Docs/API-DESIGN.md` §1.2 and #25.
    func createEmployee(_ input: Operations.CreateEmployee.Input) async throws -> Operations.CreateEmployee.Output {
        switch input.body {
        case .json(let createRequest):
            // See createDepartment: this check and the insert below are not atomic, and the
            // unique constraint added by Migrations.AddEmployeeNameUniqueness is what actually
            // prevents the duplicate by failing the second insert.
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

            // The department must exist before the employee can reference it. Checking here
            // rather than letting the foreign key reject the insert is what turns an opaque
            // constraint failure into a response naming the department that is missing.
            guard try await Models.Department.find(createRequest.departmentId, on: database) != nil else {
                return .unprocessableContent(
                    .init(
                        body: .json(
                            Components.Schemas.ReferenceError(
                                error: true,
                                reason: "No department exists with id \(createRequest.departmentId)"
                            )
                        )
                    )
                )
            }

            let newEmployee = Models.Employee()
            newEmployee.firstName = createRequest.firstName
            newEmployee.lastName = createRequest.lastName
            newEmployee.$department.id = createRequest.departmentId

            do {
                try await newEmployee.save(on: database)
            } catch let error where ConstraintViolation(error) == .unique {
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
            } catch let error where ConstraintViolation(error) == .foreignKey {
                // The department check above lost its race: the department was deleted between
                // that lookup and this insert. Before #21 this fell into the branch above and
                // reported a duplicate name that did not exist.
                return .unprocessableContent(
                    .init(
                        body: .json(
                            Components.Schemas.ReferenceError(
                                error: true,
                                reason: "No department exists with id \(createRequest.departmentId)"
                            )
                        )
                    )
                )
            }

            let employeeResponse = try Components.Schemas.Employee(newEmployee)

            return .created(.init(body: .json(employeeResponse)))
        }
    }

    /// `GET /api/employees/{employeeId}`
    ///
    /// - `200` — the employee.
    /// - `404` — no employee has that id. Sent with an empty body, which is what distinguishes
    ///   it from a routing `404`.
    func getEmployeeDetail(_ input: Operations.GetEmployeeDetail.Input) async throws
        -> Operations.GetEmployeeDetail.Output
    {
        let employeeId = input.path.employeeId

        guard let employee = try await Models.Employee.find(employeeId, on: database) else {
            return .notFound(.init())
        }

        let employeeResponse = try Components.Schemas.Employee(employee)

        return .ok(.init(body: .json(employeeResponse)))
    }

    /// `PATCH /api/employees/{employeeId}`
    ///
    /// - `200` — the updated employee. A body of `{}` changes nothing and returns it unchanged.
    /// - `404` — no employee has that id.
    /// - `409` — another employee already has the resulting first and last name.
    /// - `422` — the supplied `departmentId` does not exist.
    ///
    /// Every field is optional; omitted ones are left unchanged. See `Docs/API-DESIGN.md` §1.3.
    /// Supplying `departmentId` moves the employee to another department.
    func updateEmployee(_ input: Operations.UpdateEmployee.Input) async throws -> Operations.UpdateEmployee.Output {
        let employeeId = input.path.employeeId

        switch input.body {
        case .json(let updateRequest):
            guard let existingEmployee = try await Models.Employee.find(employeeId, on: database) else {
                return .notFound(.init())
            }

            // The constraint is on the *pair*, so uniqueness must be checked against the values
            // the row will end up with — not against what the request happened to supply. A PATCH
            // sending only `firstName` still has to be checked against the stored `lastName`.
            let newFirstName = updateRequest.firstName ?? existingEmployee.firstName
            let newLastName = updateRequest.lastName ?? existingEmployee.lastName

            // Excluding this employee's own row is what makes a no-op PATCH return 200 rather
            // than conflicting with itself. Same reasoning as updateDepartment.
            if try await Models.Employee.query(on: database)
                .filter(\.$firstName == newFirstName)
                .filter(\.$lastName == newLastName)
                .filter(\.$id != (try existingEmployee.requireID()))
                .first() != nil
            {
                let conflictResponse = Components.Schemas.ConflictError(
                    error: true,
                    reason: "An employee named '\(newFirstName) \(newLastName)' already exists"
                )
                return .conflict(.init(body: .json(conflictResponse)))
            }

            // Only checked when supplied. Omitting `departmentId` leaves the employee where it
            // is, which is the same partial-update rule the names follow — and because the
            // column is `NOT NULL`, there is no way to express "remove the department" and no
            // tri-state to disambiguate. See `Docs/API-DESIGN.md` §2.5.
            if let newDepartmentId = updateRequest.departmentId {
                guard try await Models.Department.find(newDepartmentId, on: database) != nil else {
                    return .unprocessableContent(
                        .init(
                            body: .json(
                                Components.Schemas.ReferenceError(
                                    error: true,
                                    reason: "No department exists with id \(newDepartmentId)"
                                )
                            )
                        )
                    )
                }

                existingEmployee.$department.id = newDepartmentId
            }

            existingEmployee.firstName = newFirstName
            existingEmployee.lastName = newLastName

            do {
                try await existingEmployee.save(on: database)
            } catch let error where ConstraintViolation(error) == .unique {
                // The pre-check lost the race: another request took this name in between.
                return .conflict(
                    .init(
                        body: .json(
                            Components.Schemas.ConflictError(
                                error: true,
                                reason: "An employee named '\(newFirstName) \(newLastName)' already exists"
                            )
                        )
                    )
                )
            } catch let error where ConstraintViolation(error) == .foreignKey {
                // The department was deleted between the check above and this save. Reported as
                // the reference failure it is rather than as a duplicate name (#21).
                return .unprocessableContent(
                    .init(
                        body: .json(
                            Components.Schemas.ReferenceError(
                                error: true,
                                reason:
                                    "No department exists with id "
                                    + "\(updateRequest.departmentId ?? existingEmployee.$department.id)"
                            )
                        )
                    )
                )
            }

            let employeeResponse = try Components.Schemas.Employee(existingEmployee)

            return .ok(.init(body: .json(employeeResponse)))
        }
    }

    /// `DELETE /api/employees/{employeeId}`
    ///
    /// - `204` — deleted, no body.
    /// - `404` — no employee has that id.
    func deleteEmployee(_ input: Operations.DeleteEmployee.Input) async throws -> Operations.DeleteEmployee.Output {
        let employeeId = input.path.employeeId

        guard let existingEmployee = try await Models.Employee.find(employeeId, on: database) else {
            return .notFound(.init())
        }

        try await existingEmployee.delete(on: database)

        return .noContent(.init())
    }
}
