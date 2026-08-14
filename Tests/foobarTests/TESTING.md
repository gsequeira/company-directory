# Writing assertions in this test suite

Conventions for `foobarTests`. The suite is integration-style: every test boots a real
`Application` with an in-memory SQLite database via `TestHelpers.withApplication`, drives it
over HTTP with `application.sendRequest`, and asserts on the response.

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

## Step 6 — Extract repeated setup into a helper

Once three or more tests repeat the same setup, the per-test judgment call above should be made
once, in one place. Add the helper to `TestHelpers.swift` next to the existing `sendRequest`
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
every test that fails setup blames the same line inside `TestHelpers.swift`, and the failure list
stops telling you which test broke.

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
  a test out, since it stays visible and flags up when it starts passing again.
