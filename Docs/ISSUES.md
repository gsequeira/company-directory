# Known issues in the test suite

Defects found in `Tests/foobarTests/APIHandlerTests.swift`, with their fixes. All issues recorded
here are resolved; the file is kept as a record of what went wrong and why the guards against
recurrence look the way they do. See [`TESTING.md`](TESTING.md) for the conventions these fixes
follow.

Scope note: this covers defects in the test suite itself. It is not a project-wide issue list. For
gaps in what the suite covers — including a live defect where malformed input returns `500` — see
[`API-COVERAGE.md`](API-COVERAGE.md).

**The numbering here is local to this file and predates the move to GitHub Issues.** "Issue 1" and
"Issue 2" below are test-suite defects and have nothing to do with GitHub #1 and #2. For GitHub
issues and what has been resolved, see [`ISSUE-LOG.md`](ISSUE-LOG.md).

| # | Location | Issue | Status |
| --- | --- | --- | --- |
| 1 | `testCreateEmployeeDuplicateName` | Assertion checked wording the handler never produced | **Resolved** |
| 2 | `testDeleteDepartmentNotFound` | Test passed without reaching the handler | **Resolved** |

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

**Status:** resolved, with a regression guard in place.

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

### The regression guard

Correcting the path fixed the defect but left nothing preventing its return: status alone cannot
distinguish the two `404`s this application can produce.

| Source | Status | Body |
| --- | --- | --- |
| Vapor routing (no route matched) | `404` | `{"error":true,"reason":"Not Found"}` — 35 bytes |
| `deleteDepartment` returning `.notFound(.init())` | `404` | *(empty — the spec declares no content for 404)* |

A body assertion pins which of the two is acceptable:

```swift
#expect(response.status == .notFound)
#expect(response.body.readableBytes == 0)
```

`TestingHTTPResponse.body` is a `ByteBuffer`, so `readableBytes` asserts emptiness without
decoding.

This is now in place on both `testDeleteDepartmentNotFound` and `testGetDepartmentDetailNotFound`.

### Confirming the guard works

Per Step 5 of [`TESTING.md`](TESTING.md), the assertion was checked against the bug it exists to
catch. Temporarily restoring the period in the path produced:

```
Expectation failed: (response.body.readableBytes → 35) == 0
```

The status assertion still passed on its own — only the body check noticed the handler had never
been entered. That is the failure mode the guard exists for, and it is the reason to keep the
assertion even though it looks arbitrary next to a passing status check.
