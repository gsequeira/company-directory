# Learning path

`foobar` is a learning project. The goal beyond it is being able to build substantial server-side
Swift backends — an online shopping system is the working example. This document is about the
distance between the two, and how to close it without abandoning this project.

**Written:** 2026-08-14. See [`API-DESIGN.md`](API-DESIGN.md) for the concrete roadmap of this
project's own phases; this document is the wider curriculum those phases sit inside.
Step 3 below has its own worked guide in [`POSTGRES.md`](POSTGRES.md).

## What this project already teaches

These transfer directly to a larger system and are worth being explicit about, because they are the
parts most people skip:

**Spec-first with generated types.** Adding three operations to `openapi.yaml` breaks the build
until `APIHandler` implements them, because `APIProtocol` gains three requirements. The contract is
enforced by the compiler rather than by discipline. That property is what makes this toolchain
worth the friction, and it scales to a 200-endpoint API unchanged.

**Integration tests that boot a real application.** `TestHelpers.withApplication` exercises
routing, request decoding, Fluent and the handler together. The common alternative — unit-testing
handlers against a mocked database — cannot catch a path-template mismatch or a decoding failure,
both of which this project has already hit.

**Verifying rather than assuming.** The bugs found here were found by running things: the `Int32`
overflow that killed the process, the path parameter mismatch, the test that passed without ever
entering the handler. That habit matters more than any specific framework knowledge.

## The gap: CRUD is the easy 20%

Everything built so far is *entity in, entity out*. A shopping backend's difficulty lives
elsewhere, and this project will not surface it on its current trajectory.

The concepts below are ordered by how much trouble they cause when missing.

---

### 1. Transactions and consistency

Placing an order is: decrement inventory, create the order, create its line items, record payment —
atomically, or not at all. A partial write leaves stock reserved for an order that does not exist.

There are currently no transactions anywhere in this codebase, and it already contains this class
of bug: `createDepartment` checks for an existing name and then inserts, so two concurrent requests
can both pass the check. In a directory that is a duplicate row. In a shop it is selling the last
item three times.

**What to learn:** `database.transaction { db in ... }` in Fluent, and the habit of treating
database constraints as the source of truth rather than pre-checks. A unique index rejects the
second writer; an `if` statement in a handler does not.

**Practise it here:** see Phase 3 below.

### 2. Idempotency

A payment request times out and the client retries. If the retry charges again, a customer has been
billed twice for one order.

The fix is that mutating operations accept an idempotency key — usually a client-supplied header —
and the server records it, so a repeat of the same key returns the original result rather than
performing the work again. This has to appear in the spec, which makes it a design concern rather
than an implementation detail.

**Why CRUD does not teach it:** `POST /departments` twice creating two departments is *correct*.
`POST /payments` twice charging twice is a defect. Nothing in this project makes that distinction
necessary.

### 3. Money

Never floating point. Use integer minor units (cents) or `Decimal`, consistently, from the database
column through the OpenAPI schema to the JSON on the wire. `0.1 + 0.2 != 0.3` in binary floating
point, and in a shopping cart that difference becomes a real discrepancy on a real invoice.

In OpenAPI, `type: number` is a float. Money wants `type: integer` with the unit documented, or a
string-encoded decimal. Decide once and apply it everywhere.

**Why this bites:** it is silent. Nothing fails; the totals are just slightly wrong, and only in
some cases.

### 4. State machines

An order is not a row you `PATCH`. It moves `pending → paid → shipped → delivered`, with
transitions that are illegal (`delivered → pending`) and must be rejected.

`PATCH /orders/{id}` accepting an arbitrary `status` field puts the rules in the client's hands.
The better shape names the transition:

```
POST /orders/{orderId}/ship
POST /orders/{orderId}/cancel
```

Each is an operation with its own preconditions, its own failure responses, and its own tests. This
is a genuinely different modelling skill from CRUD, and most non-trivial domains need it.

### 5. Authorization, distinct from authentication

The `401` stub in `openapi.yaml` is authentication — *are you someone*. Shopping needs
authorization — *can this someone read this order* — which is per-row rather than per-route.

Middleware can answer the first question. The second has to be answered inside the handler, because
it depends on the data being fetched. Getting this wrong is how systems leak other customers'
orders.

---

## Two changes worth making now

### Move to PostgreSQL earlier than feels necessary — **done 2026-08-14**

The argument was: Phase 2 declares a foreign key from `employees` to `departments`, and SQLite
would very likely not have enforced it, because foreign keys need `PRAGMA foreign_keys = ON` per
connection and it is off by default. You would have written `.references("departments", "id")`,
believed you had referential integrity, and not had it.

Postgres also brings real concurrent connections, actual transaction isolation, proper `numeric`
for money, and a migration story against a database that already contains data — every migration
until then had run against an empty schema, which is the easy case.

Better to discover the difference on a directory than on an orders table. The full record is in
[`POSTGRES.md`](POSTGRES.md), and it paid off faster than expected: the *very next* migration
failed on existing rows, which is written up in [`MIGRATIONS.md`](MIGRATIONS.md).

Worth noting what the move actually cost, because none of it was the driver swap. The real work
was test isolation — in-memory SQLite gave every test its own database for free, and a shared
server does not. And the sharpest lesson had nothing to do with either database: `configureServer`
fetched its own database configuration, so the tests could not choose theirs, and the suite would
have dropped the development schema while reporting success. Configuration a function reaches out
and takes for itself cannot be varied by a caller. That generalises well beyond databases.

### Add phases that are not CRUD

You do not need a new domain to meet the hard concepts — the existing one supports both of the
exercises worked out below. They are the cheapest available on-ramp to sections 1 and 4 above.

---

# Two worked exercises

The operative word is **forces**. `database.transaction { }` can be added anywhere; adding it to
`createDepartment` changes nothing observable, and you learn the syntax without the concept. Both
exercises below are chosen so that the naive implementation fails a test you can actually write.

## Phase 3 — the operation that forces a transaction

> **Move all employees from one department to another, then delete the source department.**

```yaml
  /departments/{departmentId}/transfer:
    post:
      summary: Transfer all employees to another department
      operationId: transferEmployees
      requestBody:
        required: true
        content:
          application/json:
            schema:
              properties:
                targetDepartmentId:
                  type: integer
                  format: int32
                deleteSourceAfterTransfer:
                  type: boolean
              required: [targetDepartmentId]
      responses:
        "200": { description: The employees were transferred. }
        "404": { description: Either department does not exist. }
        "409": { description: The source and target are the same department. }
```

### Why it forces one

Two writes that must both land: the bulk reassignment and the delete. If the delete fails after the
update succeeds, everyone has been moved out of a department that still exists — wrong data, and no
error surfaced to anyone.

This only becomes true after Phase 2. Without the relationship there is nothing to move, which is
why this belongs at the end of the roadmap rather than now.

### The Fluent detail that catches people

```swift
try await database.transaction { db in
    try await Models.Employee.query(on: db)      // `db`, the transaction handle
        .filter(\.$department.$id == sourceId)
        .set(\.$department.$id, to: targetId)
        .update()

    if request.deleteSourceAfterTransfer {
        try await source.delete(on: db)          // `db` again
    }
}
```

The closure hands you a `db`, and **every query inside must use it**. Writing `query(on: database)`
— the captured outer property — compiles, runs, and silently executes outside the transaction. The
result is a transaction wrapping nothing, with no warning of any kind.

This is the most common Fluent transaction bug and it is invisible until the rollback path is
tested.

### Testing the rollback — the actual exercise

The happy path passing proves nothing; the rollback is the only thing that demonstrates the
transaction exists. That needs a genuinely reachable failure, and the Phase 2 foreign key provides
one if `.restrict` was chosen:

1. Transfer employees from A to B, with a deliberate filter bug that leaves one behind.
2. Deleting A fails, because a row still references it.
3. Assert that **nobody moved** — the transferred employees are still in A.

Without the transaction, step 3 fails: most employees moved, the delete failed, and the data is now
split across two departments with nothing recording it.

The alternative is a test-only injected throw. Same lesson, less elegant — prefer the constraint
violation, because the failure is real rather than simulated.

### An aside worth noticing

Ask whether this operation is idempotent. Run it twice: the second run moves zero employees and the
source is already gone, so it `404`s. That is naturally idempotent for a different reason than a
payment endpoint would be, and thinking it through sharpens what idempotency means before reaching
a case where it has to be engineered deliberately.

## Phase 4 — the operation that forces a state machine

> **Employment status on `Employee`:** `invited → active → onLeave → active → departed`

A real requirement for a directory rather than a contrived one. `departed` is terminal: returning
to `active` must be refused, not silently allowed.

### Why it forces one

Three properties CRUD does not have:

1. **Not every change is legal.** `departed → active` must be rejected. A `PATCH` carrying a
   `status` field cannot express that — it accepts whatever it is given, which puts the rules in
   every client's hands.
2. **Transitions carry their own data.** Departing has a leaving date and possibly a reason;
   returning from leave has neither. Different request bodies mean different endpoints.
3. **Transitions have side effects.** Does departing unassign the employee from their department?
   That decision belongs to the transition, not to a field assignment.

### The endpoint shape

Name the transition rather than the field:

```
POST /employees/{employeeId}/activate
POST /employees/{employeeId}/start-leave
POST /employees/{employeeId}/depart
```

The status code that matters is **`409`** for an illegal transition — a conflict with the
resource's current state, which is precisely what `409` means. `400` would be wrong: the request is
well-formed, it is the state that is incompatible.

### What the generator gives you

```yaml
    EmploymentStatus:
      type: string
      enum: [invited, active, onLeave, departed]
```

`swift-openapi-generator` turns this into a Swift enum, making illegal *values* unrepresentable at
the type level. Illegal *transitions* still need runtime logic — keep it on the enum itself rather
than scattered across three handlers:

```swift
extension Components.Schemas.EmploymentStatus {
    func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.invited, .active), (.active, .onLeave),
             (.onLeave, .active), (.active, .departed), (.onLeave, .departed):
            return true
        default:
            return false
        }
    }
}
```

### Where it pays off in testing

A state machine produces a natural transition matrix — four states against three transitions —
which is what Swift Testing's parameterised tests exist for:

```swift
@Test("illegal transitions are rejected", arguments: [
    (EmploymentStatus.departed, "activate"),
    (EmploymentStatus.invited, "start-leave"),
    (EmploymentStatus.departed, "start-leave"),
])
func rejectsIllegalTransition(from: EmploymentStatus, endpoint: String) async throws {
    // ... expect 409
}
```

One function covering the whole illegal half of the matrix, against a current suite where every
case is hand-written.

## Where the two converge

Two concurrent requests both call `/depart` on the same employee. Both read `status == .active`,
both find the transition legal, both write — and the departure side effects run twice.

The fix is **compare-and-swap**: write the new status conditionally on the old one still being what
was read. That requires the read and the write to sit in the same transaction — Phase 3's tool
applied to Phase 4's problem, which is why doing both is worth more than doing either.

One concrete constraint: Fluent's `QueryBuilder.update()` returns `Void`, with no affected-row
count. The SQL-style `UPDATE ... WHERE status = 'active'` followed by checking whether one row
changed is therefore not directly available. Either read-then-write inside a transaction and rely
on its isolation, or drop to SQLKit for the conditional update and inspect the result.

That is an instructive limitation to meet — it is the point where the ORM stops being the whole
world.

### Order

Transaction first. It is mechanically simpler, its failure is easier to construct, and the state
machine's concurrency problem cannot be approached without the tool the transaction exercise
provides. Then the state machine. Then make one transition concurrency-safe, at which point both
exercises are doing work at once.

---

## Supporting practices

Ordered by value per minute invested.

**Continuous integration.** There are 14 passing tests and nothing running them on push. A GitHub
Actions workflow calling `swift build && swift test` is perhaps twenty lines and is the single
highest-return item on this page. Add `swift format lint --strict` once the config exists — see the
notes on that in the project's deferred work.

**Error handling as a subsystem.** The `500`-on-malformed-input defect recorded in
[`API-COVERAGE.md`](API-COVERAGE.md) is the symptom of not having one. One middleware that maps
domain errors and decoding failures onto declared status codes, applied to every route, fixes it
everywhere at once — including endpoints not yet written.

**Observability.** `swift-log` is a dependency already and is barely used. Structured logging with
a request ID threaded through each request is the baseline; `swift-metrics` and
`swift-distributed-tracing` are the next steps. In a system with payments and background jobs, "why
did this one order fail" is unanswerable without them.

**Deployment.** Everything runs on one machine. A `Dockerfile`, configuration from the environment,
and somewhere to put secrets are all prerequisites for anything real — and they change how the
application is structured, so meeting them early avoids retrofitting.

**API versioning.** Renaming `PageOfDepartments` to `DepartmentList` was free because nothing
consumed the API. That will not be true a second time. Spec-first makes breaking changes visible,
which is most of the battle, but a policy for how to evolve a live contract is still needed.

**Background work and inbound webhooks.** Order confirmation emails and payment provider callbacks
are both asynchronous. Vapor Queues covers the outbound side. Webhooks are the inbound side and
bring their own requirements — signature verification and, again, idempotency, since providers
retry.

---

## Suggested order

1. **Finish Phases 1 and 2** from [`API-DESIGN.md`](API-DESIGN.md) — employee CRUD, then the
   one-to-many relationship. This is the OpenAPI and Fluent fluency the rest depends on.
2. **Add CI**, at any point. It is independent of everything else.
3. ~~**Move to PostgreSQL**~~ — **done 2026-08-14**, ahead of steps 1 and 2, because a CI workflow
   written against SQLite would only have been rewritten a week later and Phase 2's foreign key
   needed a database that enforces one. Recorded in [`POSTGRES.md`](POSTGRES.md), with schema
   changes since in [`MIGRATIONS.md`](MIGRATIONS.md).
4. **Phase 3: the transfer operation** — transactions and non-CRUD endpoint design.
5. **Error middleware**, which also closes the `500` defect.
6. **Phase 4: employment status** — state machines, transition-named endpoints, parameterised
   tests.
7. **Make one transition concurrency-safe** — compare-and-swap, which needs Phase 3's transaction
   applied to Phase 4's problem.
8. **Then start the shopping domain**, with money, state machines and idempotency as deliberate
   exercises rather than things discovered late.

The honest summary: the approach is sound, and the rigour is already there. What is missing is not
discipline but *exposure to problems that CRUD does not have*. Steps 3 to 7 above are the cheapest
way to get that exposure without leaving a domain you already understand.
