# API test coverage

A snapshot of how much of `Sources/foobar/openapi.yaml` the suite in
`Tests/foobarTests/APIHandlerTests.swift` actually exercises, and what it misses.

**Assessed:** 2026-08-14, at commit `15405a2` (14 tests passing). **Partially re-assessed
2026-08-16** — only the `updateDepartment` rows, when #13 and #16 closed its declared-response gap
(21 tests passing). Everything else below still dates from the original sweep; a full re-assessment
is deliberately held until Phase 1 is complete, since #9 changes the employee surface. The
declared-response tables below
were re-checked after the move to PostgreSQL and the employee uniqueness migration; both left the
counts unchanged, but each added a gap — see *Constraint violations surface as 500* and the note on
`createEmployee`'s 409 below.

This is a status document and goes out of date as tests are added — unlike
[`TESTING.md`](TESTING.md), which holds the conventions for writing them, and
[`ISSUES.md`](ISSUES.md), which records specific defects. Re-check the tables below before
trusting them.

**Scope:** this audits how well the *existing* surface is tested. It does not assess whether that
surface is the right one — the employee resource is deliberately incomplete and the two entities
are not yet related. See [`API-DESIGN.md`](API-DESIGN.md) for the intended shape and the planned
sequencing, which puts most of the work below *after* the design phases.

## Summary

Every operation in the spec has at least one test, so there are no completely unexercised
endpoints. Beneath that:

- **20 of 22 declared responses are tested**, after #9 added three operations and #13/#16 closed
  `updateDepartment`.
- **Both remaining gaps cannot be tested** — the two `401`s are spec defects, not missing tests.
  Every response the server can actually produce now has a test.
- **Malformed input returns `500` on every endpoint**, an undeclared status that violates the
  contract everywhere. No test sends invalid input, which is why this went unnoticed.

### Open items

> **Status lives in GitHub Issues** as of 2026-08-14. The tracker holds what is outstanding and how
> far along it is; these documents hold the reasoning. Issues link back here rather than repeating
> the explanation, so read the doc for *why* and the issue for *whether it is done*. Don't copy
> prose between them — that is how one of them becomes quietly wrong.

| Item | Kind | Where |
| --- | --- | --- |
| The two `401` declarations describe authentication that does not exist, and are asymmetric | Spec defect | [below](#the-two-401s-are-spec-defects-not-test-gaps--needs-addressing) |
| Malformed input returns `500` instead of `400` on every endpoint | Implementation defect | [below](#undeclared-behaviour-malformed-input-returns-500) |
| Invalid-input and `Int32` overflow tests. `updateDepartment` 404/409 and self-rename are **done** (#13, #16) | Missing tests | [below](#recommended-additions-in-priority-order) |

## Declared-response coverage

| Operation | Declared | Tested | Missing |
| --- | --- | --- | --- |
| `listDepartments` | 200 | 200 | — |
| `createDepartment` | 201, 401, 409 | 201, 409 | **401** |
| `getDepartmentDetail` | 200, 404 | 200, 404 | — |
| `updateDepartment` | 200, 404, 409 | 200, 404, 409 | — |
| `deleteDepartment` | 204, 404 | 204, 404 | — |
| `listEmployees` | 200 | 200 | — |
| `createEmployee` | 201, 401, 409 | 201, 409 | **401** |
| `getEmployeeDetail` | 200, 404 | 200, 404 | — |
| `updateEmployee` | 200, 404, 409 | 200, 404, 409 | — |
| `deleteEmployee` | 204, 404 | 204, 404 | — |

### `updateDepartment` was the weak spot — closed 2026-08-16

Three declared responses, one tested. Both missing paths had been verified by hand against a running
server and behaved correctly:

- `PATCH /api/departments/999` → `404`, empty body.
- `PATCH` renaming a department onto a name another department already holds → `409` with
  `"A department with the name 'Engineering' already exists"`.

They were missing tests rather than bugs, and #13 and #16 closed all three. `updateDepartment` is
now fully covered against its declared responses.

**What the closing found**, which matters more than the coverage number: the `409` test does **not**
distinguish which code path produced the conflict. Deleting the entire pre-check from
`updateDepartment` leaves all 21 tests passing, because the unique index then rejects the `save` and
the `catch` returns the same `409`. The two paths are indistinguishable from outside, so neither is
individually pinned. That is #17's territory — see *Findings that outlived their issue* in
[`ISSUE-LOG.md`](ISSUE-LOG.md).

### The two `401`s are spec defects, not test gaps — NEEDS ADDRESSING

There is no authentication anywhere in the codebase. The spec documents a response the
implementation cannot produce, so no test can be written for it.

The problem is not only that it is unimplemented. `401` is declared on `createDepartment` and
`createEmployee` and **on nothing else** — so as written, the spec says creating a department
requires authentication while updating and deleting one does not. Implementing exactly what is
documented would leave `PATCH` and `DELETE` open. The asymmetry suggests these blocks were
copied rather than chosen.

**Relevant constraint:** `swift-openapi-generator` does not support `security`, `securitySchemes`,
or Security Requirement objects — all are unchecked in its `Supported-OpenAPI-features.md`.
Declaring security in the spec therefore generates and enforces nothing; it is documentation for
humans and other tooling only. Enforcement has to be hand-written Vapor middleware regardless.

**Option A — delete the declarations.** Remove the two `"401"` blocks. Two lines each, no code or
test changes, and the spec then honestly describes an unauthenticated API. Recommended as the
immediate step: a spec advertising authentication that does not exist is more dangerous than one
advertising none, because a client team may assume the server rejects unauthenticated calls and
skip their own checks.

**Option B — implement authentication.** Three pieces of work, of which the spec change is the
smallest:

1. Declare `components.securitySchemes` plus a top-level `security` key, and add `401` to **all
   seven** operations — ideally via a shared `components.responses.Unauthorized` rather than
   repeating the block.
2. Write an `AsyncMiddleware` that checks the credential and throws `Abort(.unauthorized)`.
   Compare tokens in constant time; `==` short-circuits and leaks length and prefix through timing.
3. Register it as `application.grouped(...)` and pass that group to `VaporTransport` as the routes
   builder, so the API is protected but `/health` — registered directly on the application — stays
   reachable for load balancer probes. Source the credential from the environment and fail startup
   if it is missing; a default token is worse than no authentication because it looks protected.

Two consequences to plan for: middleware rejects before the generated handler runs, so the `401`
body will be Vapor's `{"error":true,"reason":"Unauthorized"}` rather than anything the spec
describes; and `TestHelpers.withApplication` will need to supply a credential or all existing tests
begin failing with `401`.

## Undeclared behaviour: malformed input returns 500

Every request the suite sends is well-formed, so this entire class of input is unexercised.
Verified against a running server on 2026-08-14:

| Request | Actual | Should be |
| --- | --- | --- |
| `GET /api/departments/abc` | **500** | 400 |
| `GET /api/departments/3000000000` (> `Int32.max`) | **500** | 400 |
| `POST /api/departments` with `{}` | **500** | 400 |
| `POST /api/departments` with truncated JSON (`{"name":`) | **500** | 400 |
| `POST /api/departments` with `{"name":123}` | **500** | 400 |

A client-side typo produces `"Server error"`. `500` is not declared for any operation, so this
breaks the contract on all seven. The cause is that `swift-openapi-vapor` surfaces request-decoding
failures as unhandled errors rather than mapping them to `400`; an error middleware would fix it
centrally.

### Historical note on the out-of-range case

`GET /api/departments/3000000000` used to **crash the process** — the handler called the trapping
`Int32(...)` initialiser on a value the spec typed as 64-bit `Int`, and the resulting
`Fatal error: Not enough bits to represent the passed value` took the server down. Declaring
`format: int32` in the spec made the generator emit the parameter as `Int32`, which moved the
failure into parsing.

It now returns the wrong status instead of dying, which is a real improvement — but nothing in the
suite pins that behaviour, so there is no guard against a regression.

## Constraint violations — fixed, but still untested

Raised and resolved 2026-08-14. Previously, when the duplicate pre-check *lost* a race — two
concurrent requests both passed it and the database rejected the second insert — the client got a
`500` rather than the declared `409`. `createDepartment`, `updateDepartment` and `createEmployee`
now catch the constraint failure and return `409`; see
[`MIGRATIONS.md`](MIGRATIONS.md) and [`FLUENT.md`](FLUENT.md).

**The suite still does not cover it.** The existing duplicate-name tests exercise the pre-check
path, which answers before the database is consulted, so they would pass unchanged if the mapping
were deleted tomorrow. That is a live example of the Step 5 problem in
[`TESTING.md`](TESTING.md): a branch with no test holding it in place.

It was verified manually, deterministically, using an uncommitted transaction to force the race —
the recipe is in [`MIGRATIONS.md`](MIGRATIONS.md). Turning that into an automated test is possible
but needs a second connection held open inside the test, which is more machinery than the suite has
today. Worth doing when Phase 2 arrives, because the foreign key changes this code's correctness.

**Known limitation:** the mapping keys on "any constraint failure", the only vocabulary the
driver-agnostic API offers. Uniqueness is currently the sole constraint on both tables, so that is
exact. Once `employees.department_id` has a foreign key, a request naming a nonexistent department
will be reported as a duplicate name.

## Smaller gaps

**`createEmployee`'s 409 is now backed by a constraint.** It previously was not — the check was a
bare read-then-write with nothing behind it. That is fixed, but note the design consequence
recorded in [`API-DESIGN.md`](API-DESIGN.md) §1.2: the schema now forbids two employees sharing a
name, which is a modelling limitation rather than a resolved question.

**Empty names are accepted.** `POST /api/departments` with `{"name":""}` returns `201` and creates
a department with an empty name. The spec sets no `minLength`, so this is technically conformant,
but it is unlikely to be intended. Fix in the spec rather than the handler if it is not.

**~~Self-rename is untested.~~ Tested since 2026-08-16 (#16).** `PATCH` on a department using its
own current name correctly returns `200` rather than `409`. That behaviour depends entirely on the
`.filter(\.$id != (try existingDepartment.requireID()))` line in `updateDepartment` — deleting that
line used to leave the whole suite passing. It now fails exactly one test, with `409` where `200`
was expected. This is the "assertion that cannot fail" problem from Step 5 of [`TESTING.md`](TESTING.md),
one level up: a whole branch with no test holding it in place.

**~~The employee resource is a stub.~~ Closed 2026-08-16 (#9).** `/employees/{employeeId}` now
declares `GET`, `PATCH` and `DELETE`, and all three are tested. The employee tests no longer look
thin next to the department ones.

**The merge in `updateEmployee` is not pinned by any test.** Under partial update the uniqueness
pre-check must combine the supplied fields with the stored ones — patching only `firstName` still
has to be checked against the stored `lastName`. Breaking that merge leaves all 30 tests passing,
because the resulting row still violates the unique index and the `catch` returns the same `409`
with the same body. This is the `updateDepartment` finding from #13 in a second place: the two
`409` paths are indistinguishable from outside, so only the outcome is pinned, never the route to
it. Belongs to #17.

## Recommended additions, in priority order

1. ~~**`updateDepartment` 404 and 409.**~~ **Done 2026-08-16 (#13)**, landed green as expected.
2. **One invalid-input test per shape** — bad path parameter, missing required field, malformed
   JSON body. These will **fail** until the `400` mapping exists. ~~Decide whether to land them red
   as executable documentation of the defect, or hold them until the middleware is written.~~
   **Resolved 2026-08-16:** neither. Land them now inside `withKnownIssue`, asserting the `400`
   they should return — the run stays green, and each test fails the moment #2 fixes it. See
   [`TESTING.md`](TESTING.md) → *Step 7*.
3. **`Int32.max + 1` as a regression test.** Given this used to take the process down, it earns a
   permanent guard regardless of which status it settles on.
4. ~~**Self-rename returns `200`.**~~ **Done 2026-08-16 (#16)**, and the filter is now load-bearing:
   deleting it fails that test and only that test.

## Reproducing this assessment

The declared-response table is derived from `openapi.yaml` and the `@Test` blocks, so it can be
regenerated by reading both. The behavioural findings need a running server:

```sh
docker compose up -d --wait               # see Docs/POSTGRES.md
swift build
.build/debug/foobar &                     # binds 127.0.0.1:8080
http --print=h :8080/api/departments/abc  # --print=h shows the status line only
pkill -f '.build/debug/foobar'
```

**Re-verified 2026-08-14 on PostgreSQL:** `GET /api/departments/abc` still answers
`HTTP/1.1 500 Internal Server Error`. The defect is in path-parameter decoding, ahead of any
database work, so the move off SQLite neither fixed nor worsened it.

Note the database is no longer in-memory. Probing now writes to the `foobar_db` Docker volume and
persists; `docker compose down -v` resets it.
