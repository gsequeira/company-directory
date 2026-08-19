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
///   eleven operations. Tracked by #2; see `Docs/API-COVERAGE.md` and `Docs/MIDDLEWARE.md`.
struct APIHandler: APIProtocol {
    let database: Database

    /// A seam that exists for one test, and is `nil` everywhere else.
    ///
    /// `transferEmployees` runs two writes in a transaction, and the only evidence the transaction
    /// exists is that a failure between them rolls the first one back. With this schema there is no
    /// way to make the delete fail *after* a correct update: the update moves every employee out of
    /// the source, and nothing else references a department. The failure is reachable only in the
    /// window between the two writes, which no client can aim at.
    ///
    /// So the test supplies a closure that inserts an employee into the source department on a
    /// separate connection and commits it. The delete then fails against a real `onDelete:
    /// .restrict` foreign key rather than a thrown stub, which is the failure a client would
    /// actually hit by losing that race. `Docs/API-DESIGN.md` §3.2 records why that race is real.
    ///
    /// Kept as an explicit parameter rather than a mutable global so the coupling is visible in the
    /// signature. Production code never sets it.
    var beforeSourceDelete: (@Sendable () async throws -> Void)?

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

    /// `POST /api/departments/{departmentId}/transfer`
    ///
    /// Moves every employee out of this department into another, and optionally deletes this one
    /// once it is empty. The first operation here that is not CRUD, and the first that needs a
    /// transaction: both writes land or neither does.
    ///
    /// - `200` — how many employees moved, and whether the source was deleted.
    /// - `404` — no department has that id. The source is the resource in the path, so it answers
    ///   with an empty body like every other `{departmentId}` operation.
    /// - `409` — the delete was refused because an employee was assigned to the source while the
    ///   transfer was running. Reachable only by losing that race.
    /// - `422` — the target does not exist, or is the source. Both are named in the *body*, which
    ///   is what separates them from the `404`. `Docs/API-DESIGN.md` §3.3 has the rule.
    func transferEmployees(_ input: Operations.TransferEmployees.Input) async throws
        -> Operations.TransferEmployees.Output
    {
        switch input.body {
        case .json(let transferRequest):
            let sourceId = input.path.departmentId
            let targetId = transferRequest.targetDepartmentId

            guard let source = try await Models.Department.find(sourceId, on: database) else {
                return .notFound(.init())
            }

            if targetId == sourceId {
                return .unprocessableContent(
                    .init(
                        body: .json(
                            Components.Schemas.ReferenceError(
                                error: true,
                                reason: "Department \(sourceId) cannot be transferred into itself"
                            )
                        )
                    )
                )
            }

            guard try await Models.Department.find(targetId, on: database) != nil else {
                return .unprocessableContent(
                    .init(
                        body: .json(
                            Components.Schemas.ReferenceError(
                                error: true,
                                reason: "No department exists with id \(targetId)"
                            )
                        )
                    )
                )
            }

            let deleteSource = transferRequest.deleteSourceAfterTransfer ?? false
            let transferred: Int

            do {
                transferred = try await database.transaction { db in
                    // **Every query in this closure uses `db`, the transaction handle.** Writing
                    // `query(on: database)` here — the captured outer property — compiles, runs,
                    // and executes outside the transaction, leaving it wrapping nothing. Nothing
                    // in the compiler or in Fluent reports that, and every happy-path test still
                    // passes. The rollback test is what catches it.
                    let employees = try await Models.Employee.query(on: db)
                        .filter(\.$department.$id == sourceId)
                        .all()

                    // The count has to be of the rows actually moved. Counting separately and then
                    // updating by filter would drift: a row inserted between the two statements is
                    // moved but not counted. `Docs/API-DESIGN.md` §3.1 records why, and why Fluent
                    // leaves no third option — `QueryBuilder.update()` returns `Void`.
                    let ids = try employees.map { try $0.requireID() }

                    if !ids.isEmpty {
                        try await Models.Employee.query(on: db)
                            .filter(\.$id ~~ ids)
                            .set(\.$department.$id, to: targetId)
                            .update()
                    }

                    try await beforeSourceDelete?()

                    if deleteSource {
                        try await source.delete(on: db)
                    }

                    return ids.count
                }
            } catch let error where ConstraintViolation(error) == .foreignKey {
                // An employee was assigned to the source between the move and the delete, so the
                // `.restrict` foreign key refused it and the whole transaction rolled back.
                // Nobody moved, and the message says nothing about a count for the same reason
                // `deleteDepartment`'s race path does not.
                return .conflict(
                    .init(
                        body: .json(
                            Components.Schemas.ConflictError(
                                error: true,
                                reason:
                                    "Department '\(source.name)' was given an employee while the "
                                    + "transfer was running, so nothing was transferred"
                            )
                        )
                    )
                )
            }

            return .ok(
                .init(
                    body: .json(
                        Components.Schemas.TransferResult(
                            transferred: transferred,
                            sourceDeleted: deleteSource
                        )
                    )
                )
            )
        }
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
