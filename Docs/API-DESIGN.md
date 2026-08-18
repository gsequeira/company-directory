# API design and roadmap

Where the API surface stands, what is deliberately not built yet, and the decisions that need
making along the way.

**Intent, as of 2026-08-14:** get `Department` and `Employee` working correctly as independent
resources first, then connect them in a one-to-many relationship (a department has many employees).
This is a learning project for spec-first API design with OpenAPI, Swift and Vapor, so this
document explains the mechanics involved rather than only listing the work.

Companion documents: [`API-COVERAGE.md`](API-COVERAGE.md) audits how well the *existing* surface is
tested, [`FLUENT.md`](FLUENT.md) explains the ORM layering these handlers sit on,
[`TESTING.md`](TESTING.md) holds assertion conventions,
[`MIDDLEWARE.md`](MIDDLEWARE.md) covers the cross-cutting layer the generated handlers cannot
express, [`ISSUES.md`](ISSUES.md) records
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
§1.3.

**They are related as of 2026-08-17 (#18).** `Models.Employee` has a non-optional `@Parent`, the
`employees` table has a required `department_id` with `onDelete: .restrict`, and the `Employee`
schema carries `departmentId`. Phase 2 is complete; §2.1 records where the implementation departed
from the sketch. Phase 3 adds the transfer operation and Phase 4 employment status — neither is
built yet, and the Phase 4 decisions are recorded in §4.2 through §4.6.

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

**Implemented 2026-08-17 (#18), with one departure from the sketch below.** `departmentId` is on
`Employee`, `CreateEmployeeRequest` and — not anticipated here — `UpdateEmployeeRequest`, so an
employee can be moved between departments. It is optional there, following the same partial-update
rule as the names.

The response for an unknown department is **`422`, not the `404` this section proposed.** `404`
does not survive contact with `updateEmployee`, which already returns `404` with an empty body to
mean *no such employee*, and where the empty body is what distinguishes a handler `404` from a
routing one. One status cannot carry both meanings on the same operation, and OpenAPI cannot
declare a response whose body is sometimes present. `422 Unprocessable Content` says what is
actually true: the request is well-formed and the addressed resource exists, but something it
names does not. `ReferenceError` is the body schema.

`deleteDepartment` also gains `409`, per §2.4.

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

**Done 2026-08-17.** The one-line sketch above turned into three migrations, because `.required`
cannot be applied to a column that already exists: `AddEmployeeDepartment` (nullable, foreign key
live), `BackfillEmployeeDepartment`, then `RequireEmployeeDepartment`, which needs raw SQL. The
negative test was written first and passed immediately, which is the payoff described above —
`Tests/CompanyDirectoryTests/ForeignKeyTests.swift`.

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

## Decided 2026-08-16 — restrict, enforced in both places

`DELETE /departments/{id}` returns `409` while any employee still references the department.

**Nullify was eliminated by §2.5**, not chosen against — it requires a nullable column, and there
is not one.

**Cascade was rejected.** Deleting a department would delete the people in it, which is
indefensible for a directory, and it is the irreversible direction: restrict → cascade is a
behavioural change clients absorb, cascade → restrict breaks every client that relied on it.

### Enforced twice, deliberately

| Layer | Job |
| --- | --- |
| Pre-check in the handler | Count the employees and return a `409` that says how many |
| Foreign key on the column | Refuse the delete when the pre-check loses a race |

Neither alone is enough. The pre-check alone races — an employee can be inserted between the count
and the delete. The foreign key alone gives the client nothing to act on: it surfaces as a generic
constraint failure, and since `isConstraintFailure` currently means "duplicate name", a department
delete would answer *"A department with the name … already exists"*. Confidently wrong, which this
project treats as worse than silence.

This is the same shape `createDepartment` already uses for duplicate names, so it is the
established pattern here rather than a new one.

Verified rather than assumed: FluentKit's `references(_:space:_:onDelete:onUpdate:)` defaults
`onDelete` to `.noAction`, and PostgreSQL refuses the delete on `NO ACTION` just as it does on
`RESTRICT` — they differ only in when the check fires. So the database would protect the data even
if the handler forgot. **Declare `.restrict` explicitly anyway**, because the intent should be
readable in the migration rather than inferred from a default.

### This makes #21 part of #18, not a follow-up

The moment the foreign key exists, `isConstraintFailure` stops meaning "duplicate name". Four
`catch` blocks — in `createDepartment`, `updateDepartment`, `createEmployee` and `updateEmployee` —
become able to fire for a foreign-key violation and report a duplicate name that does not exist.

Shipping the relationship without narrowing that mapping means four handlers that can lie. #21 is
therefore folded into #18 rather than left downstream of it.

### Spec change

`409` needs declaring on `deleteDepartment`, with the `ConflictError` schema the other conflict
responses already use.

## 2.5 Decision — is a department required?

`@Parent` requires a value; `@OptionalParent` allows null. Requiring one means a new employee
cannot be created before their department exists, and there is no way to represent someone between
departments. Making it optional means every read path has to handle the null case.

For a company directory, required is the simpler model and the more accurate one. Note it forces an
ordering constraint on clients: create the department first.

## Decided 2026-08-16 — required, via `@Parent`

Every employee belongs to a department. The column is `NOT NULL` and the model uses `@Parent`.

**The deciding argument is one §1.3 deferred.** That section accepted, knowingly, that a generated
optional cannot distinguish "leave this field alone" from "clear it", and recorded that the bill
would come due in Phase 2 — because un-assigning an employee would mean setting `departmentId` to
null. **Requiring the column means the bill never arrives.** There is nothing to clear, so the
tri-state problem stays theoretical. Choosing optional would have meant solving it: either a
tri-state wrapper the generator will not produce, or adopting JSON Merge Patch, both of which §1.3
rejected for good reasons that have not changed.

**"Unassigned" is better modelled as a department than as null.** A real row named *Unassigned* is
queryable, appears in `GET /departments`, has an id a client can `PATCH` someone into, and needs no
special case anywhere. Null is a state every consumer must remember to handle, forever, and that no
listing ever shows.

Reads also stay simple: `SchemaConversions.swift` keeps producing non-optional values, and
`departmentId` is a plain required field on the `Employee` schema.

### The two costs this accepts

**Clients must create the department before the employee.** A real ordering constraint, though a
directory naturally acquires departments before people.

**The migration is the actual work in this decision.** `employees` is already populated, so a
`NOT NULL` foreign key cannot simply be added. It needs three steps in sequence — add the column
nullable, backfill every existing row to a department, then apply the `NOT NULL` constraint — or a
default pointing at an existing row. [`MIGRATIONS.md`](MIGRATIONS.md) lists this under *Not yet
encountered*; #18 is where it stops being theoretical. Append, never amend: this is a new migration,
not an edit to `CreateEmployees`.

## 2.6 Optional — the nested collection route

`GET /departments/{departmentId}/employees` becomes natural once the relationship exists, and it is
the obvious place to use `@Children`. Not required — `GET /employees?departmentId=…` covers the
same need with a filter — but it is worth building once to see how the generator handles nested
paths and how `.with(\.$employees)` eager loading works.

---

# Phase 3 — the transfer operation

`POST /departments/{departmentId}/transfer` moves every employee in one department to another and
optionally deletes the source. It is the first operation here that is not CRUD and the first that
needs a transaction: two writes that must both land, or neither.

**The decisions are open on #65** — the response shape, whether `deleteSourceAfterTransfer` belongs
on the operation at all, `409` versus `422` for a same-department request, and what idempotency
means for it. They are not recorded here because they are not made. The implementation is #66.

[`LEARNING-PATH.md`](LEARNING-PATH.md) → *Phase 3 — the operation that forces a transaction* holds
the reasoning and the spec sketch.

---

# Phase 4 — employment status

## 4.1 The shape

`Employee` gains a status with a fixed transition graph:

```
invited → active → onLeave → active → departed
```

`departed` is terminal. Transitions are named endpoints rather than a field on `PATCH`:

```
POST /employees/{employeeId}/activate
POST /employees/{employeeId}/start-leave
POST /employees/{employeeId}/depart
```

An illegal transition returns `409` — a conflict with the resource's current state, which is what
`409` means. `400` would be wrong: the request is well-formed, and it is the state that is
incompatible.

Three properties make this different from the CRUD in Phases 1 and 2, and each one is a reason the
field cannot simply be added to `UpdateEmployeeRequest`:

| Property | Consequence |
| --- | --- |
| Not every change is legal | A `PATCH` accepts what it is given, so the rules would live in every client |
| Transitions carry their own data | Departing has a leaving date and a reason; returning from leave has neither |
| Transitions have side effects | Those belong to the transition, not to a field assignment |

The rules live on the generated enum rather than across three handlers:

```swift
extension Components.Schemas.EmploymentStatus {
    func canTransition(to next: Self) -> Bool { … }
}
```

Note that `409` is already this API's duplicate-name code. [`ISSUE-LOG.md`](ISSUE-LOG.md) records
two occasions — under #13 and #9 — where a test asserting only on `409` could not tell which code
path produced it, and where the pre-check turned out to be deletable with the suite still green.
Transition tests assert on the response body as well as the status.

## 4.2 Decision — the backfill value and the column default

## Decided 2026-08-18 — backfill `active`, default `invited`, and the state set is final

The four states are settled: `invited`, `active`, `onLeave`, `departed`. No `suspended`, no
`contractor`. That is what makes §4.5 available.

Existing rows backfill to `active`. Everyone already in the table is current staff, `invited` would
misrepresent them as not yet onboarded, and there is no data from which to reconstruct who was ever
invited. New rows default to `invited`.

The backfill value and the column default therefore differ, deliberately. The default describes how
a record starts from now on; the backfill describes rows that predate the concept and could never
have started that way.

Mechanically this is #18's shape — add the column with a default, backfill, then apply `NOT NULL` in
a second migration, because Fluent cannot express "add non-null with a default" in one step. See
[`MIGRATIONS.md`](MIGRATIONS.md) → *Steps 2 and 3*.

**What "settled" costs.** With the native enum of §4.5, a state added in error is permanent short of
creating a new type, altering the column and dropping the old one. Accepted, because adding a state
also requires rewriting `canTransition(to:)`, a new endpoint, an extended transition matrix and a
migration. The schema was never the binding constraint.

## 4.3 Decision — does departing unassign the employee from their department

## Decided 2026-08-18 — it does not; §2.5 stands unchanged

`depart` changes status and nothing else about the relationship. `departmentId` stays required and
non-null, the `@Parent` stays non-optional, and no migration touches the column. Status and
assignment are orthogonal: one records whether someone works here, the other where they worked.

Making `departmentId` nullable was rejected. It would reverse §2.5, reintroduce the absent-versus-null
cost §1.3 deferred, and destroy the record of which department someone departed from.

### The follow-on that looks right and is not

Filtering departed employees out of `deleteDepartment`'s pre-check, so a department empties as its
staff leave, breaks — because the pre-check and the database would disagree. The foreign key is
`onDelete: .restrict` (`Migrations.swift:93`), so PostgreSQL refuses the delete while *any* row
references the department. The pre-check would pass, the `DELETE` would fail, and the request would
land in the race-path `catch` at `APIHandler.swift:206`, returning a `409` that deliberately quotes
no count. The caller would see a conflict on a department the API had just implied was empty.

Making that filter honest would require changing the foreign key, and the only options are
`SET NULL` — the nullable route, already rejected — or `CASCADE`, which deletes people because their
department closed.

**So `deleteDepartment` is unchanged: all employees count, departed included.** A department cannot
be hard-deleted while anyone who ever worked there still exists as a row. That is the correct
restriction; the alternative is losing history to a `DELETE`. #66's transfer operation is the
intended path — move everyone to the receiving department, then delete the source. Its fidelity cost
is accepted: transferring a departed employee rewrites where they are recorded as having departed
from.

Archiving a department rather than deleting it, and modelling employment as a history of assignments
rather than one current assignment, are the proper answers to that restriction. Both are larger than
Phase 4 and are deliberately not folded in here.

## 4.4 Decision — can a departed employee still be edited

## Decided 2026-08-18 — yes, fully; only `status` is off-limits to `PATCH`

`PATCH /employees/{employeeId}` behaves identically whatever the employee's status. No new `409`, no
per-field rule, no handler code. The one new restriction is that `status` is not a member of
`UpdateEmployeeRequest` at all, for any employee.

Immutability is not available rather than merely unattractive. §4.3 makes #66's transfer the escape
hatch for deleting a department, and departed employees still hold a `departmentId` that blocks the
delete — so transfer has to be able to move them. A rule that froze `PATCH` but not transfer would
be worse than no rule.

Per-field mutability — names correctable, department frozen — is rejected because
`openapi.yaml` cannot express it. OpenAPI has no way to say a field is writable only in some
resource states, so the rule would live in handler code, be invisible to every generated client, and
surface only as a runtime `409`. That is the objection that removed the undeclarable `401`s in #11
and that chose `422` over `404` in §2.1. It is also arbitrary: correcting a mis-recorded department
is no less legitimate than correcting a misspelled name.

What enforces terminality is the transition graph — `canTransition(to:)` and the three endpoints
returning `409` — not `PATCH`. `status` appears in `Employee` responses and is absent from
`UpdateEmployeeRequest` deliberately; that asymmetry is worth a comment in `openapi.yaml` so it does
not read as an oversight.

Audit trails, and protecting a leaving date from later correction, are out of scope.

## 4.5 Decision — storage form for a closed value set

## Decided 2026-08-18 — native enum for `EmploymentStatus`, `CHECK` for anything that is opinion

The criterion, which matters more than either answer: **is the value set defined by the domain, or
by current opinion?**

A native PostgreSQL enum cannot have a value removed. Verified against PostgreSQL 18:

```
ALTER TYPE salutation DROP VALUE 'Miss';
ERROR:  dropping an enum value is not implemented
```

A `varchar` with a `CHECK` refuses for a better reason — live rows still hold the value — and
succeeds once the data is corrected. That immovability is only a cost when the set is opinion.

`EmploymentStatus` takes a **native enum**. A state machine's value set is the machine; §4.2 settles
it, and adding a state was never going to be a schema-only change. Sort order is the second reason:

| | Order |
| --- | --- |
| Native enum | `invited < active < onLeave < departed` (declaration order) |
| `varchar` | `active < departed < invited < onLeave` (alphabetical) |

`ORDER BY status` becoming meaningful matters for #22 and #23; the alternative is a `CASE` expression
in every query or a separate sort-key column.

A field like `salutation` takes a `CHECK`, and should be nullable. Its set is opinion and already
contested — `Mr | Mrs | Miss` omits `Ms`, encodes marital status for women and not for men, and has
no room for `Dr` or `Prof`. A set still under discussion should not be stored in a form that cannot
be narrowed.

### What the native-enum path costs, all verified

- **Revert has an order of its own.** `DROP TYPE` fails while a column uses it — *"cannot drop type
  employment_status because other objects depend on it"*. Drop the column, then the type. This is the
  first migration here whose `revert()` has ordering constraints, and it is worth a worked example
  in [`MIGRATIONS.md`](MIGRATIONS.md).
- **A new value cannot be used in the transaction that added it** — *"New enum values must be
  committed before they can be used"*. Harmless today, because FluentKit's `Migration/` directory
  contains no use of `transaction` and migrations autocommit statement by statement. It becomes a
  live tripwire if migrations are ever made transactional.
- **`.deleteCase()` is a silent no-op.** `FluentPostgresDriver`'s `execute(enum:)` logs *"PostgreSQL
  does not support deleting enum cases"* at `.debug` and proceeds with only the additions, so the
  migration reports success and changes nothing. Cited without a line number deliberately: it is
  dependency source, and the line moves between releases.
- **A bad value arrives as SQLSTATE `22P02`**, a data exception, not class 23. It falls outside
  `ConstraintViolation.swift`, which models integrity-constraint violations; a `CHECK` failure is
  `23514` and lands in the family that file already covers.

In this application the generated enum rejects an invalid value during decoding, before any SQL runs.
The database constraint is a backstop for writers that bypass the API — `psql`, migrations, a future
service — not the primary guard.

## 4.6 Decision — `status` in responses, and filtering

## Decided 2026-08-18 — in responses from day one and required; no implicit filter, ever

`status` is a member of `Employee` from the first migration, declared `required` rather than
optional: the column is non-null once the backfill completes, and an optional field that is never
absent teaches every client to handle a case the server cannot produce. The three transition
endpoints also have no observable effect without it.

`GET /api/employees` returns every employee, departed included. Filtering belongs to #23, where
`status` is the obvious first argument.

Hiding departed employees by default is rejected permanently rather than deferred, because it
contradicts §4.3 observably. `deleteDepartment` counts every employee, so its `409` reads *"still
has 3 employees assigned to it"* while a list that silently omitted the departed one would show two
— two different counts for the same department, with nothing in the spec explaining why. A default
filter is also undeclarable: OpenAPI can describe a `status` parameter and its default, but not "this
collection silently omits some members".

The accepted consequence is that employee lists grow monotonically. That is an argument for #22 and
#23 mattering sooner, not for hiding rows.

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

**Authentication.** Not implemented, and no longer declared — #11 removed the two `401` blocks on
2026-08-16 so the spec matches the server. The design is on #24 and the mechanism in
[`MIDDLEWARE.md`](MIDDLEWARE.md).

**A declared `400`.** No operation declares a response for malformed input, and the server
currently answers `500`. Whatever fixes that should also add `400` to the spec — including on the
new employee operations, so the gap is not reproduced.

---

# Sequencing

1. **Phase 1** — employee CRUD, plus the uniqueness and `PATCH` decisions. Complete 2026-08-16.
2. **Phase 2** — the relationship, plus the delete-semantics and required-department decisions.
   Complete 2026-08-17.
3. **Phase 3** — the transfer operation, and the transaction it forces. Decisions open on #65,
   implementation #66.
4. **Phase 4** — employment status, and the state machine it forces. Decisions closed (§4.2–§4.6),
   implementation #68, then #69 for the concurrency-safe transition.
5. **Then** the work in [`API-COVERAGE.md`](API-COVERAGE.md).

Phase 3 before Phase 4 is deliberate. The transaction is mechanically simpler and its failure is
easier to construct, and the state machine's concurrency problem in #69 cannot be approached without
the tool the transfer exercise provides.

Coverage work last is deliberate. Writing `updateDepartment` tests now means writing near-identical
`updateEmployee` tests immediately afterwards, and Phase 2 changes the `Employee` schema — which
would invalidate employee tests written before it. The exception is the `500`-on-malformed-input
defect: that is a single error-middleware fix that benefits every endpoint, present and future, so
it is worth doing whenever it becomes annoying rather than waiting for its place in the queue.
