# Known issues in `foobarTests`

Defects found in `APIHandlerTests.swift`, with their fixes. Both original issues are now resolved;
one has a residual hardening step still open. See [`TESTING.md`](TESTING.md) for the conventions
these fixes follow.

Scope note: this covers the test suite only. It is not a project-wide issue list, and does not
track defects in `Sources/foobar`.

| # | Location | Issue | Status |
| --- | --- | --- | --- |
| 1 | `testCreateEmployeeDuplicateName` | Assertion checked wording the handler never produced | **Resolved** |
| 2 | `testDeleteDepartmentNotFound` | Test passed without reaching the handler | **Resolved**, one hardening step open |

---

## Issue 1 — Conflict assertion checked wording the handler never produced

**Status:** resolved.

### What was wrong

The assertion expected a message the implementation never emitted:

```swift
#expect(conflictError.reason.contains("Duplicate names"))
```

`createEmployee` builds its conflict message from the submitted names:

```swift
// APIHandler.swift
reason: "An employee named '\(createRequest.firstName) \(createRequest.lastName)' already exists"
```

The failure was:

```
Expectation failed: (conflictError.reason → "An employee named 'Jane Doe' already exists")
  .contains("Duplicate names")
```

The three assertions before it all passed — status `409`, JSON content type, `error == true` — so
duplicate detection itself was working. Only the wording assertion failed. The test appears to have
been written against a planned message before the handler settled on phrasing consistent with the
department handlers.

### The fix

```swift
#expect(conflictError.reason.contains("Jane Doe"))
```

This asserts the substantive contract — the message identifies which employee collided — and
survives rewording of "already exists".

### Optional follow-up

The literal `"Jane Doe"` duplicates the fixture that produced it. Deriving it removes the chance of
the two drifting apart:

```swift
#expect(conflictError.reason.contains("\(createRequest.firstName) \(createRequest.lastName)"))
```

`testCreateDepartmentDuplicateName` has the same shape — it matches against the literal
`"Duplicate Department"` rather than `createRequest.name`. Not broken, just repeated.

---

## Issue 2 — Delete-not-found test never reached the handler

**Status:** resolved. One hardening step still open.

### What was wrong

The path used a period where it needed a slash:

```swift
let response = try await application.sendRequest(.DELETE, "/api/departments.999")
#expect(response.status == .notFound)
```

`/api/departments.999` is a single path component, not `/api/departments/999`. No route matched it,
so Vapor's router returned its own `404` before any generated OpenAPI handler ran. The assertion
saw the status it wanted and passed — for a completely different reason than intended.

The test was green, and would have stayed green if `deleteDepartment` were deleted from
`APIHandler` entirely. That is the hazard: it reported coverage of the delete-404 path that did not
exist.

### The fix

The path is now correct:

```swift
let response = try await application.sendRequest(.DELETE, "/api/departments/999")
#expect(response.status == .notFound)
```

The route `/api/departments/{departmentId}` now matches, `deleteDepartment` runs, `find(999)`
returns nil, and the handler returns `.notFound(.init())`.

### Still open — prove it reaches the handler

The test no longer asserts anything that distinguishes the two `404`s:

| Source | Status | Body |
| --- | --- | --- |
| Vapor routing (no route matched) | `404` | `{"error":true,"reason":"Not Found"}` |
| `deleteDepartment` returning `.notFound(.init())` | `404` | *(empty — the spec declares no content for 404)* |

Status alone cannot tell them apart, so a future path typo would silently reintroduce the original
bug. Adding a body assertion closes that:

```swift
#expect(response.status == .notFound)
#expect(response.body.readableBytes == 0)
```

`TestingHTTPResponse.body` is a `ByteBuffer`, so `readableBytes` asserts emptiness without
decoding.

To confirm the test is load-bearing after adding it: make `deleteDepartment` return a different
status, check the test goes red, then restore the handler.

### Related

`testGetDepartmentDetailNotFound` uses the correct `/api/departments/999` and does reach the
handler, but likewise asserts status only. The same `readableBytes` check would strengthen it
symmetrically.
