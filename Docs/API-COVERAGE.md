# API test coverage

A snapshot of how much of `Sources/foobar/openapi.yaml` the suite in
`Tests/foobarTests/APIHandlerTests.swift` actually exercises, and what it misses.

**Assessed:** 2026-08-14, at commit `15405a2` (14 tests passing).

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

- **11 of 15 declared responses are tested.**
- **2 of the 4 gaps cannot be tested** — they are spec defects, not missing tests.
- **Malformed input returns `500` on every endpoint**, an undeclared status that violates the
  contract everywhere. No test sends invalid input, which is why this went unnoticed.

### Open items

| Item | Kind | Where |
| --- | --- | --- |
| The two `401` declarations describe authentication that does not exist, and are asymmetric | Spec defect | [below](#the-two-401s-are-spec-defects-not-test-gaps--needs-addressing) |
| Malformed input returns `500` instead of `400` on every endpoint | Implementation defect | [below](#undeclared-behaviour-malformed-input-returns-500) |
| `updateDepartment` 404/409, invalid-input, `Int32` overflow and self-rename tests | Missing tests | [below](#recommended-additions-in-priority-order) |

## Declared-response coverage

| Operation | Declared | Tested | Missing |
| --- | --- | --- | --- |
| `listDepartments` | 200 | 200 | — |
| `createDepartment` | 201, 401, 409 | 201, 409 | **401** |
| `getDepartmentDetail` | 200, 404 | 200, 404 | — |
| `updateDepartment` | 200, 404, 409 | 200 | **404, 409** |
| `deleteDepartment` | 204, 404 | 204, 404 | — |
| `listEmployees` | 200 | 200 | — |
| `createEmployee` | 201, 401, 409 | 201, 409 | **401** |

### `updateDepartment` is the weak spot

Three declared responses, one tested. Both missing paths were verified by hand against a running
server and behave correctly:

- `PATCH /api/departments/999` → `404`, empty body.
- `PATCH` renaming a department onto a name another department already holds → `409` with
  `"A department with the name 'Engineering' already exists"`.

So these are missing tests, not bugs. Two tests close the gap.

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

## Smaller gaps

**Empty names are accepted.** `POST /api/departments` with `{"name":""}` returns `201` and creates
a department with an empty name. The spec sets no `minLength`, so this is technically conformant,
but it is unlikely to be intended. Fix in the spec rather than the handler if it is not.

**Self-rename is untested.** `PATCH` on a department using its own current name correctly returns
`200` rather than `409`. That behaviour depends entirely on the `.filter(\.$id !=
existingDepartment.id!)` line in `updateDepartment` — delete that line and the whole suite still
passes. This is the "assertion that cannot fail" problem from Step 5 of [`TESTING.md`](TESTING.md),
one level up: a whole branch with no test holding it in place.

**The employee resource is a stub.** The spec declares only `GET` and `POST` on `/employees` —
there is no detail, update or delete operation, and no `/employees/{employeeId}` path at all. That
is a spec gap rather than a coverage gap, but it means the employee tests will look thin next to
the department ones for reasons that have nothing to do with test quality.

## Recommended additions, in priority order

1. **`updateDepartment` 404 and 409.** Closes the declared-response gap. Both verified to behave
   correctly, so these land green.
2. **One invalid-input test per shape** — bad path parameter, missing required field, malformed
   JSON body. These will **fail** until the `400` mapping exists. Decide whether to land them red
   as executable documentation of the defect, or hold them until the middleware is written.
3. **`Int32.max + 1` as a regression test.** Given this used to take the process down, it earns a
   permanent guard regardless of which status it settles on.
4. **Self-rename returns `200`.** Makes the `$id !=` filter load-bearing.

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
