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
| Read one | `GET /departments/{departmentId}` | `GET /employees/{employeeId}` |
| Update | `PATCH /departments/{departmentId}` | `PATCH /employees/{employeeId}` |
| Delete | `DELETE /departments/{departmentId}` | `DELETE /employees/{employeeId}` |

**Both entities have full CRUD as of 2026-08-16 (#9).** `PATCH` is a partial update on both — see
§1.3. The two entities remain unrelated: `Models.Employee` has no `@Parent`, the `employees` table
has no `department_id`, and the `Employee` schema has no `departmentId`. That is Phase 2.

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

Since `Employee` has two fields, this decision lands immediately — and Phase 2 adds a third.

The two coherent answers were **partial update** (drop `required`, keep `PATCH`) and **full
replacement** (keep `required`, rename the verb to `PUT`). What is not coherent, and what the code
did, is `PATCH` with required fields.

## Decided 2026-08-16 — partial update, applied to both resources

`PATCH` stays, `required` goes. Omitted fields are left unchanged.

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

**This applies to `UpdateDepartmentRequest` too**, in the same pull request, so the two resources
never disagree about what `PATCH` means. That work rides along with #9 rather than getting its own
issue, since #9 already edits both the spec and `APIHandler`.

### Why `PUT` was rejected

Not on aesthetics — on how the two options age.

`PUT` means *replace the resource with this representation*, and a department's representation
includes the server-assigned `id`. So a strict `PUT` body ought to carry `id`, which buys a new rule
to police (what happens when the body's `id` disagrees with the path's) and a test for it. The
alternative is a `PUT` whose body is not the resource — the same species of incoherence this
decision exists to remove.

It also ages badly into Phase 2. Once `Employee` carries `departmentId`, every rename must resend
the department assignment, so a client holding a stale copy silently reassigns the employee while
trying to fix a typo. That is the classic lost-update hazard: `PUT` invites it, `PATCH`
structurally cannot express it.

`PUT` remains the better verb for genuinely idempotent whole-document resources — a config
blob, an object store, anything where the client legitimately owns the entire representation. That
is not what these endpoints are.

### What this costs, since it is not free

**An empty body is now a valid request.** `PATCH` with `{}` means "change nothing" and returns
`200` with the unchanged resource. Rejecting it was tempting, but a client that builds a patch by
diffing will legitimately produce an empty patch when nothing changed, and a `400` there forces
every caller to special-case emptiness.

One side effect worth naming so it is not mistaken for a fix: `PATCH /api/departments/{id}` with
`{}` currently returns `500`, one row in the malformed-input table in
[`API-COVERAGE.md`](API-COVERAGE.md). This decision deletes that row by making the input valid. The
underlying defect — malformed input returning `500` rather than `400` — is untouched.

**Absent and `null` collapse into the same value.** A generated `String?` cannot distinguish "leave
this alone" from "set this to nothing". That costs nothing today, because no field is nullable. It
lands in **Phase 2**, where un-assigning an employee from a department is precisely "set
`departmentId` to null". How swift-openapi-generator represents `nullable: true` on an optional
property is unverified — test it when Phase 2 arrives rather than assuming.

**One `if let` per field, permanently.** Fine at two fields. Revisit the shape if a request schema
ever reaches roughly eight.

### The alternatives that solve the null problem properly

[RFC 7396 JSON Merge Patch](https://www.rfc-editor.org/rfc/rfc7396) (`application/merge-patch+json`)
gives `null` an explicit meaning — *delete this field* — while absent still means *leave it*.
[RFC 6902 JSON Patch](https://www.rfc-editor.org/rfc/rfc6902) goes further, sending an operation
list (`[{"op": "replace", "path": "/name", "value": "…"}]`), which also buys array edits and
test-then-apply preconditions.

**Neither is right here, and the reason is the reason this project exists.** Both fight typed code
generation: Merge Patch needs a tri-state wrapper the generator will not produce, and JSON Patch
abandons a typed body altogether for an opaque operation array — discarding the schema that makes
spec-first worth doing. Reach for Merge Patch when a resource grows a nullable field clients
genuinely need to clear, and not before.

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

**Watch for N+1 the moment this lands.** If `listEmployees` starts returning a department name,
`employee.department.name` issues one query *per employee* — it reads like a property access
because it is one. `.with(\.$department)` collapses that to two queries total. See
[`FLUENT.md`](FLUENT.md) → *The N+1 problem*, including how to detect it by counting queries per
request rather than by how fast it feels at these row counts.

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
