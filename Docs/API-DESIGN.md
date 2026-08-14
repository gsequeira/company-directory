# API design and roadmap

Where the API surface stands, what is deliberately not built yet, and the decisions that need
making along the way.

**Intent, as of 2026-08-14:** get `Department` and `Employee` working correctly as independent
resources first, then connect them in a one-to-many relationship (a department has many employees).
This is a learning project for spec-first API design with OpenAPI, Swift and Vapor, so this
document explains the mechanics involved rather than only listing the work.

Companion documents: [`API-COVERAGE.md`](API-COVERAGE.md) audits how well the *existing* surface is
tested, [`FLUENT.md`](FLUENT.md) explains the ORM layering these handlers sit on,
[`TESTING.md`](TESTING.md) holds assertion conventions, [`ISSUES.md`](ISSUES.md) records
defects found and fixed, and [`LEARNING-PATH.md`](LEARNING-PATH.md) sets these phases in the wider
context of building larger backends. [`POSTGRES.md`](POSTGRES.md) works through the database move
that §2.3 below argues should happen before Phase 2. This document is about what the API *should*
contain.

## Where the API stands

| Operation | Department | Employee |
| --- | --- | --- |
| List | `GET /departments` | `GET /employees` |
| Create | `POST /departments` | `POST /employees` |
| Read one | `GET /departments/{departmentId}` | — |
| Update | `PATCH /departments/{departmentId}` | — |
| Delete | `DELETE /departments/{departmentId}` | — |

`Department` has full CRUD and serves as the reference implementation. `Employee` has list and
create only — the `/employees/{employeeId}` path does not exist in the spec at all. The two
entities are currently unrelated: `Models.Employee` has no `@Parent`, the `employees` table has no
`department_id`, and the `Employee` schema has no `departmentId`.

---

# Phase 1 — complete the two entities independently

## 1.1 Employee CRUD

Three operations to add, mirroring the department ones. The spec changes are mechanical, which is
the point — the department path is the worked example to copy.

Add a parameter component alongside the existing `path.departmentId`:

```yaml
components:
  parameters:
    path.employeeId:
      name: employeeId
      in: path
      required: true
      schema:
        type: integer
        format: int32
```

`format: int32` matters. It is what makes the generator emit `Swift.Int32` for the parameter,
matching `@ID` on the model. Omitting the format yields `Swift.Int` and forces a conversion in the
handler — the department path used to have exactly that problem, and the trapping `Int32(...)`
conversion it required could crash the server on a large ID.

Then the path itself:

```yaml
  /employees/{employeeId}:
    parameters:
      - $ref: "#/components/parameters/path.employeeId"
    get:
      summary: Retrieve an employee
      operationId: getEmployeeDetail
      tags: [employees]
      responses:
        "200":
          description: The employee was retrieved successfully.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Employee"
        "404":
          description: No employee exists with the specified ID.
    patch:
      summary: Update an employee
      operationId: updateEmployee
      tags: [employees]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/UpdateEmployeeRequest"
      responses:
        "200":
          description: The employee was updated successfully.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Employee"
        "404":
          description: No employee exists with the specified ID.
    delete:
      summary: Delete an employee
      operationId: deleteEmployee
      tags: [employees]
      responses:
        "204":
          description: The employee was deleted successfully.
        "404":
          description: No employee exists with the specified ID.
```

Plus an `UpdateEmployeeRequest` schema — see the `PATCH` decision below before writing it.

Adding these to the spec makes the build fail until `APIHandler` implements the new methods, since
`APIProtocol` gains three requirements. That is spec-first working as intended: the contract
changes first, and the compiler enumerates the work.

## 1.2 Decision — should duplicate employee names conflict?

`createEmployee` currently returns `409` when first and last name match an existing employee.

Two problems. Real organisations have two people with the same name, so this rejects legitimate
data. And unlike departments — which have a genuine unique index on `name` — the employees table
has no constraint behind the check, so it is also a read-then-write race that two concurrent
requests can both pass.

**Recommendation was:** drop the check and the `409` from `createEmployee`. Identity belongs to the
`id`, not the name. If you want a duplicate-detection feature later, a warning on read is a better
shape than a hard rejection on write.

## Decided 2026-08-14 — keep the 409, back it with a constraint

The other direction was taken. `Migrations.AddEmployeeNameUniqueness` adds a unique constraint on
`(first_name, last_name)`, so the check is no longer a bare read-then-write race. The migration and
what it taught are written up in [`MIGRATIONS.md`](MIGRATIONS.md).

**This bakes in "no two employees may share a name"**, which remains a real modelling limitation
rather than a solved problem — the first genuine John Smith collision is a schema change, not a bug
fix. Revisit it when the directory holds real people.

**Also done:** `createDepartment`, `updateDepartment` and `createEmployee` now map a constraint
violation to `409`, so the losing side of a race no longer gets a `500`. The mechanism, and the
reason it stops being exact once Phase 2 adds a foreign key, is in [`FLUENT.md`](FLUENT.md).

## 1.3 Decision — `PATCH` semantics

`UpdateDepartmentRequest` marks `name` as `required`, so a client must send every field. That is
`PUT` semantics under a `PATCH` verb. With one field the difference is invisible; with two it
becomes real, because a client cannot update one field without already knowing the other.

Since `Employee` has two fields, this decision lands immediately:

```yaml
    UpdateEmployeeRequest:
      description: The fields to update. Omitted fields are left unchanged.
      properties:
        firstName:
          type: string
        lastName:
          type: string
      # no `required` — this is what makes it a partial update
```

Omitting `required` makes the generated Swift properties optional, and the handler applies only
what is present:

```swift
if let firstName = updateRequest.firstName { employee.firstName = firstName }
if let lastName = updateRequest.lastName { employee.lastName = lastName }
```

The alternative is honest too: keep everything required and change the verb to `PUT`. What is not
coherent is `PATCH` with required fields. Whichever you choose, apply it to
`UpdateDepartmentRequest` as well so the two resources behave the same way.

---

# Phase 2 — the one-to-many relationship

A department has many employees; an employee belongs to one department.

## 2.1 Spec changes

Add `departmentId` to the `Employee` schema and to `CreateEmployeeRequest`:

```yaml
    Employee:
      properties:
        id:
          type: integer
        departmentId:
          type: integer
          format: int32
          description: The department this employee belongs to.
        firstName:
          type: string
        lastName:
          type: string
      required: [id, departmentId, firstName, lastName]
```

`POST /employees` then needs a `404` (or `422`) for the case where the referenced department does
not exist — a response neither entity needs today, and the first place the two resources interact
at the contract level.

## 2.2 Model changes

Fluent expresses the relationship from both sides:

```swift
// Employee — the "many" side owns the foreign key
@Parent(key: "department_id")
var department: Models.Department

// Department — the "one" side, derived, no column of its own
@Children(for: \.$department)
var employees: [Models.Employee]
```

Two things worth knowing:

- `@Parent` exposes both `employee.department` (the loaded model, requiring
  `.with(\.$department)` on the query) and `employee.$department.id` (the raw foreign key, always
  available). Assign the ID directly when creating: `employee.$department.id = departmentId`.
- `@Children` is *not* a stored property. It has no column and no migration. Reading it requires
  an explicit `.with(\.$employees)` or `.query(on:)`, otherwise accessing it traps.

## 2.3 Migration

```swift
.field("department_id", .int32, .required, .references("departments", "id", onDelete: .restrict))
```

`CreateEmployees` must run after `CreateDepartments`, which the current order in
`Database.swift` already satisfies.

**Resolved 2026-08-14.** This section used to carry a warning that SQLite does not enforce foreign
keys unless `PRAGMA foreign_keys = ON` is set per connection — so `.references(...)` would have been
recorded in the schema and silently not enforced, and you would have believed you had referential
integrity without having it. That was the argument for moving to PostgreSQL first, which is now
done; see [`POSTGRES.md`](POSTGRES.md).

The constraint will therefore be real the first time it exists. Prove it rather than assume it —
write the test that inserts an employee with a `department_id` matching no department, and watch it
**fail**. On the old stack it would have passed for the wrong reason, which is the single most
useful thing this project has demonstrated about picking a database.

Note also that this is a new migration, not an edit to `CreateEmployees` — that one has already run
here. Adding a `.required` column to a table that already holds rows needs care, and the sequence
is covered in [`MIGRATIONS.md`](MIGRATIONS.md).

## 2.4 Decision — what `DELETE /departments/{id}` does with employees

Currently unanswerable, because the question cannot arise. Once the relationship exists, pick one:

| Behaviour | Result | Notes |
| --- | --- | --- |
| **Restrict** | `409` if the department still has employees | Safest; forces the caller to reassign first |
| **Cascade** | Deleting a department deletes its employees | Dangerous for a directory — a mis-click removes people |
| **Nullify** | Employees keep existing with no department | Requires `@OptionalParent` and a nullable column |

**Recommendation:** restrict, with a `409` and a message saying how many employees still reference
the department. It is the only option where an accidental delete is recoverable, and it is easy to
relax later — going from restrict to cascade is a behavioural change; going the other way breaks
clients that relied on cascade.

Whatever you choose, the `409` needs declaring on `deleteDepartment` in the spec.

## 2.5 Decision — is a department required?

`@Parent` requires a value; `@OptionalParent` allows null. Requiring one means a new employee
cannot be created before their department exists, and there is no way to represent someone between
departments. Making it optional means every read path has to handle the null case.

For a company directory, required is the simpler model and the more accurate one. Note it forces an
ordering constraint on clients: create the department first.

## 2.6 Optional — the nested collection route

`GET /departments/{departmentId}/employees` becomes natural once the relationship exists, and it is
the obvious place to use `@Children`. Not required — `GET /employees?departmentId=…` covers the
same need with a filter — but it is worth building once to see how the generator handles nested
paths and how `.with(\.$employees)` eager loading works.

---

# Deferred, and deliberately so

**Pagination.** Both list endpoints return every row. The response schemas are named
`DepartmentList` and `EmployeeList` precisely because they carry no page metadata — the names were
changed from `PageOf…` so they stop implying a capability that does not exist. Adding real
pagination later means query parameters plus a metadata object in the response, which is a breaking
change to the schema. Fine to defer at this size; worth deciding before any client depends on the
current shape.

**Filtering and search.** A directory eventually needs "find people whose name starts with…".
Related to pagination, since both are query-parameter concerns on the same endpoints.

**Authentication.** See the `401` section in [`API-COVERAGE.md`](API-COVERAGE.md). The spec
currently declares `401` on two operations and implements none.

**A declared `400`.** No operation declares a response for malformed input, and the server
currently answers `500`. Whatever fixes that should also add `400` to the spec — including on the
new employee operations, so the gap is not reproduced.

---

# Sequencing

1. **Phase 1** — employee CRUD, plus the uniqueness and `PATCH` decisions.
2. **Phase 2** — the relationship, plus the delete-semantics and required-department decisions.
3. **Then** the work in [`API-COVERAGE.md`](API-COVERAGE.md).

Coverage work last is deliberate. Writing `updateDepartment` tests now means writing near-identical
`updateEmployee` tests immediately afterwards, and Phase 2 changes the `Employee` schema — which
would invalidate employee tests written before it. The exception is the `500`-on-malformed-input
defect: that is a single error-middleware fix that benefits every endpoint, present and future, so
it is worth doing whenever it becomes annoying rather than waiting for its place in the queue.
