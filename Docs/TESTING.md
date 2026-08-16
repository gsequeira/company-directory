# Writing assertions in this test suite

Conventions for the tests in `Tests/foobarTests/`. The suite is integration-style: every test boots
a real `Application` via `TestHelpers.withApplication`, drives it over HTTP with
`application.sendRequest`, and asserts on the response.

This document covers *how* to write an assertion. For *what* is currently covered and what is
missing, see [`API-COVERAGE.md`](API-COVERAGE.md); for the intended API shape and roadmap, see
[`API-DESIGN.md`](API-DESIGN.md); for specific defects found and fixed, see
[`ISSUES.md`](ISSUES.md).

## Before writing a test: how isolation works now

This changed on 2026-08-14 and it affects what you can assume.

The suite used to run on an in-memory SQLite database, which gave every `Application` its own
private schema for free. It now runs on the shared PostgreSQL server defined as `db-test` in
`docker-compose.yml`, so **you must start it first**:

```bash
docker compose up -d --wait db-test
swift test
```

Isolation now comes from two mechanisms that only work together:

- **`.serialized`** on the `@Suite`, so only one test runs at a time.
- **`autoRevert()`** in `withApplication`, which drops every table when a test finishes, so the
  next one starts from an empty schema.

Remove either and tests corrupt each other. Both carry comments saying so; leave them there.

Two consequences for how you write tests. You can still assume an empty database at the start of
every test, exactly as before — that assumption is now *earned* rather than free. And do not add
`.serialized`-defeating tricks like spawning concurrent work that outlives the test body, because
the revert will run underneath it.

The mechanics, and the database-per-test upgrade available if the suite ever gets slow enough to
need it, are in [`POSTGRES.md`](POSTGRES.md) step 6.

## The governing principle

> An assertion earns its place when its absence would make a failure **invisible** or send you
> to the **wrong file**.

Assertions are not free. Each one is a line to read, maintain, and update when behavior changes.
An assertion that restates something the very next line already guarantees is noise; an assertion
that is missing where a failure could pass silently is a bug waiting to be misdiagnosed. Both
failure modes are real, and the sections below are about telling them apart.

## Step 1 — Classify every request in the test

Each `sendRequest` call is one of two things:

- **Subject** — the behavior this test exists to verify.
- **Setup** — a request made only to reach the state the subject needs.

A test has exactly one subject (possibly followed by a verification request that confirms the
subject's side effect). Everything before it is setup. Name the subject in the `@Test` display
string so this stays obvious:

```swift
@Test("DELETE /api/departments/{departmentId} removes a department from the list")
```

Here the two POSTs are setup, the DELETE is the subject, and the trailing GET is verification.

## Step 2 — Choose `#expect` or `#require`

This is the most important distinction in the suite, and it follows directly from the
classification above.

| Macro | Behavior on failure | Use for |
| --- | --- | --- |
| `#expect(...)` | Records an issue, **test continues** | Assertions about the subject |
| `try #require(...)` | Records an issue, **throws and stops the test** | Preconditions that must hold for the test to mean anything |

Use `#expect` for the subject because you want the full picture: if a response has the wrong
status *and* the wrong body, reporting both in one run tells you more than reporting the first
and bailing.

Use `try #require` for setup because continuing past a broken precondition produces a cascade of
downstream failures that all point away from the actual cause. One failure at the real line beats
five failures at innocent ones.

```swift
// Setup — if this didn't work, nothing after it is meaningful.
try #require(createResponse.status == .created)

// Subject — report everything that's wrong with it.
#expect(deleteResponse.status == .noContent)
```

`#require` also unwraps optionals, which is the clean way to reach into a collection without
force-unwrapping:

```swift
let first = try #require(departmentList.departments.first)
#expect(first.name == "Engineering")
```

## Step 3 — Decide whether setup needs an assertion at all

Not every setup request needs one. Ask: **is the response decoded?**

**Decoded — no assertion needed.** The decode is already a precondition check.

```swift
let createResponse = try await application.sendRequest(.POST, "/api/departments", body: createRequest)
let createdDepartment = try createResponse.content.decode(Components.Schemas.Department.self)
```

If that POST returned `409`, the body is a `ConflictError` and decoding into `Department` throws
on the missing `id` and `name` keys. If it returned `404`, the body is empty and it throws too.
Either way the test stops at the setup line with a decode error. Adding
`try #require(createResponse.status == .created)` here buys a clearer message and nothing more —
acceptable, but not required.

**Discarded — assert.** When the result goes to `_`, a failed setup is completely silent.

```swift
// Silent if this fails: the test breaks later, somewhere unrelated.
_ = try await application.sendRequest(.POST, "/api/departments", body: department1)

// Better:
let response = try await application.sendRequest(.POST, "/api/departments", body: department1)
try #require(response.status == .created)
```

Concretely: if the first POST in a "list returns two departments" test failed silently, the test
fails on `departments.count == 2` and you start debugging `listDepartments`, which is fine code.

The compiler helps enforce this. An unused `let` binding triggers
`initialization of immutable value was never used`. Treat that warning as the question *"should
this setup be asserted?"* rather than as a prompt to write `_ =`.

## Step 4 — Assert on the subject, in this order

1. **Status** — always.
2. **Content type** — when a body is expected. Skip it for `204`/empty responses.
3. **Body** — decode into the generated `Components.Schemas` type and assert on fields.

```swift
#expect(response.status == .created)
#expect(response.headers.contentType == .json)

let createdDepartment = try response.content.decode(Components.Schemas.Department.self)
#expect(createdDepartment.name == "Customer Support")
#expect(createdDepartment.id > 0)
```

Decoding into the generated type is itself a contract check: it fails if the handler's response
drifts from `openapi.yaml`. Prefer it over poking at raw JSON.

### Assert on data, not prose

Error messages are wording; the data inside them is behavior. Pin the data.

```swift
// Brittle — breaks the next time someone rewords the message.
#expect(conflictError.reason.contains("Duplicate names"))

// Durable — checks the substantive claim: the message names the offending record.
#expect(conflictError.reason.contains("Jane Doe"))
```

Better still, derive the expected substring from the request that caused the conflict, so the test
and the fixture cannot drift apart:

```swift
#expect(conflictError.reason.contains("\(createRequest.firstName) \(createRequest.lastName)"))
```

### Verify side effects through the API

For mutations, asserting the response status is not enough — confirm the state actually changed by
reading it back:

```swift
#expect(deleteResponse.status == .noContent)

let fetchResponse = try await application.sendRequest(.GET, "/api/departments/\(department.id)")
#expect(fetchResponse.status == .notFound)
```

A handler that returns `204` without deleting anything passes the first assertion and fails the
second.

## Step 5 — Check that the assertion can actually fail

An assertion that passes for the wrong reason is worse than no assertion, because it reports
coverage you do not have. Before committing a negative-path test, confirm the request reaches the
code you think it does.

This suite had exactly this bug. `testDeleteDepartmentNotFound` used to read:

```swift
// `.999` is not a path separator, so no route matches and Vapor's own 404 satisfies
// the assertion. This passed even when deleteDepartment was never entered.
let response = try await application.sendRequest(.DELETE, "/api/departments.999")
#expect(response.status == .notFound)
```

The status was right, so the test was green, but nothing in `APIHandler` ran. The cheap check:
break the handler on purpose and confirm the test goes red. If it stays green, the test is not
testing what its name claims.

This matters most for `404` and `409` paths, where the framework can produce the same status as the
handler for entirely different reasons. When the distinction matters, assert on the body too — the
handler's `404` has an empty body, Vapor's routing `404` carries
`{"error":true,"reason":"Not Found"}`:

```swift
#expect(response.status == .notFound)
#expect(response.body.readableBytes == 0)   // proves the handler produced this 404
```

`TestingHTTPResponse.body` is a `ByteBuffer`, so `readableBytes` asserts emptiness without
decoding.

### The concurrency version of this trap

Same failure, one level up. Verifying that a race returns `409` rather than `500` by firing 125
concurrent duplicate requests produced a perfect-looking result — one `201`, the rest `409`, no
`500`s — and proved nothing. `pg_stat_database.xact_rollback` had not moved, so no insert ever
reached the database and the pre-check had answered every one. The client's process startup was
slower than the race window.

**A concurrency test whose requests never actually overlap reports success for the wrong reason.**
Measure something that proves the code path ran — a rollback counter, a log line, a row that should
not exist — rather than trusting the status code. The deterministic alternative, forcing the race
with an uncommitted transaction, is in [`MIGRATIONS.md`](MIGRATIONS.md).

## Step 6 — Extract repeated setup into a helper

Once three or more tests repeat the same setup, the per-test judgment call above should be made
once, in one place. Add the helper to `Tests/foobarTests/TestHelpers.swift` next to the existing `sendRequest`
extensions:

```swift
extension Application {
    func createDepartment(
        name: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Components.Schemas.Department {
        let response = try await sendRequest(
            .POST, "/api/departments",
            body: Components.Schemas.CreateDepartmentRequest(name: name)
        )
        try #require(response.status == .created, sourceLocation: sourceLocation)
        return try response.content.decode(Components.Schemas.Department.self)
    }
}
```

Thread `sourceLocation` through so a setup failure is reported at the **calling test**. Without it,
every test that fails setup blames the same line inside `Tests/foobarTests/TestHelpers.swift`, and the failure list
stops telling you which test broke.

## Step 7 — Testing behaviour that is known to be wrong

Sometimes the correct assertion fails, because the thing being asserted is a filed defect. Malformed
input returning `500` instead of `400` (#2) is the standing example here.

There are three ways to handle it and only one of them is good.

| Approach | What it costs |
| --- | --- |
| Assert the wrong behaviour — `#expect(status == .internalServerError)` | A passing test is a claim the behaviour is **correct**. The fix then breaks a green test, and in the meantime the suite vouches for the defect |
| Write nothing until the fix lands | The intended behaviour is undocumented, and nothing tells you when it starts working |
| `withKnownIssue` | Nothing, if the issue is filed and scheduled |

```swift
@Test("PATCH with no body is rejected")
func testMissingBody() async throws {
    try await TestHelpers.withApplication { application in
        await withKnownIssue("Malformed input returns 500 until #2 lands the error middleware") {
            let response = try await application.sendRequest(.PATCH, "/api/departments/1")
            #expect(response.status == .badRequest)
        }
    }
}
```

The assertion states what *should* happen. While the defect exists the run stays green, and the
moment someone fixes it the test **fails** — because Swift Testing reports an error when a known
issue stops being recorded. The test is a tripwire that tells the fix it is finished.

Both halves were verified on 2026-08-16 rather than taken from the documentation:

```
1: defect still present  recorded a known issue … (response.status → 500) == (.badRequest → 400)
                         passed after 0.058 seconds with 1 known issue
2: defect absent         recorded an issue: Known issue was not recorded
                         failed after 0.041 seconds with 1 issue
```

**The condition on using it: one issue number in the comment, or do not use it.** Without that it
becomes a place to park failures indefinitely, which is worse than having no test — the suite
reports green while asserting nothing. `withKnownIssue` is for a defect that is filed and scheduled,
not for one that is merely known.

It also has a narrower use than commenting a test out, and should always win that comparison: a
commented-out test is invisible to the runner and rots silently.

## Checklist

Before committing a test:

- [ ] Each request is identifiable as subject or setup.
- [ ] Setup uses `try #require`; the subject uses `#expect`.
- [ ] Discarded setup responses (`_ =`) are either asserted or genuinely irrelevant.
- [ ] The subject asserts status, then content type, then decoded body fields.
- [ ] Body assertions target data, not error prose.
- [ ] Mutations are verified by reading state back through the API.
- [ ] The test fails when the handler is deliberately broken.
- [ ] The `@Test` display name matches what the assertions actually check.

## Reference

- `#expect(...)` — record and continue.
- `try #require(...)` — record, throw, stop. Also unwraps optionals.
- `#expect(throws: SomeError.self) { ... }` — assert a call throws.
- `withKnownIssue { ... }` — mark a known failure without failing the run; prefer over commenting
  a test out, since it stays visible and flags up when it starts passing again. See *Step 7* for
  the conditions on using it.
