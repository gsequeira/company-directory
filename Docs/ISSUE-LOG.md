# Issue log

One row per GitHub issue that has been worked, with a pointer to where its reasoning ended up.

**Written 2026-08-15**, when #1 became the first issue taken through the
[`WORKFLOW.md`](WORKFLOW.md) routine end to end.

## What this file is, and what it is not

This is an **index**, not an archive. Every row is a pointer. The full account of any issue already
exists in four permanent places — the issue thread, the pull request body, the commit messages, and
the linked branch — and copying that prose here would duplicate it into a fifth place that nothing
keeps current.

What the rest of `Docs/` holds is the *durable lesson*, filed under the topic a future reader would
actually search. Someone asking "how do I run a Linux build locally?" opens `WORKFLOW.md`; they do
not know, and should not need to know, that CI happened to be issue 1. This file exists only to
answer the one question the topic documents scatter: **what has actually been finished, and where
did each one leave its mark.**

Which means the rule for maintaining it is narrow: add a row when an issue merges, and never write
a paragraph here. If a row wants to grow into an explanation, that explanation belongs in the topic
document and the row should link to it instead.

> **Not to be confused with [`ISSUES.md`](ISSUES.md).** That file is scoped to defects found in the
> test suite itself, and numbers them independently — its "Issue 1" and "Issue 2" are test-suite
> defects with no relation to GitHub #1 and #2. This file tracks GitHub issue numbers. The
> overlapping names are an accident of the backlog moving into GitHub after `ISSUES.md` was
> written.

## Resolved

| # | Issue | What landed | Where the lesson lives | PR |
| --- | --- | --- | --- | --- |
| 1 | Add CI to run the test suite on push | `.github/workflows/ci.yml` — Linux job on `swift:6.3.3` with PostgreSQL 18 as a service container, 14/14 green on amd64 | [`CI.md`](CI.md) (the playbook); [`WORKFLOW.md`](WORKFLOW.md) → *Where the checks run*; [`POSTGRES.md`](POSTGRES.md) → *What this unlocks* | [#27](https://github.com/sequeiralabs/foobar/pull/27) |
| 7 | Remove the no-op `do`/`catch` blocks in `APIHandler` | Seven `do { … } catch { throw error }` wrappers deleted; the three inner `catch let error as any FluentKit.DatabaseError where error.isConstraintFailure` blocks survive byte-identical. 157 insertions / 185 deletions, every one of them indentation — `git diff --ignore-all-space` is empty | [`WORKFLOW.md`](WORKFLOW.md) → *Verifying a change that should not change behaviour* | [#29](https://github.com/sequeiralabs/foobar/pull/29) |
| 8 | Seven `id!` force unwraps rely on an unwritten invariant | `Sources/foobar/SchemaConversions.swift` — throwing initializers on the *schema* types, so the dependency points API → model and regenerating the spec cannot ripple into `Models.swift`. Six sites collapse to `try …map(Components.Schemas.Department.init)`; the seventh is a query filter calling `requireID()` directly. Four new unit tests, 18/18 | [`FLUENT.md`](FLUENT.md) → `requireID()` and `FluentError.idRequired`; the file header in `SchemaConversions.swift` | [#31](https://github.com/sequeiralabs/foobar/pull/31) |

| 10 | Decide PATCH semantics: partial update, or rename to PUT | **Partial update.** `PATCH` stays, `required` goes, omitted fields are left unchanged, `{}` is a valid no-op returning `200`. No code — the application rides along with #9, which must change `UpdateEmployeeRequest` and `UpdateDepartmentRequest` together | [`API-DESIGN.md`](API-DESIGN.md) §1.3 — including why `PUT` was rejected, the absent-vs-`null` cost deferred to Phase 2, and why JSON Merge Patch is the right tool but not yet | [#32](https://github.com/sequeiralabs/foobar/pull/32) |
| 13, 16 | `updateDepartment` 404 and 409; self-rename returns 200 | Three tests in `APIHandlerTests`, closing the last declared-response gap on `updateDepartment`. Done *before* #9 rather than inside it, so they were written against the current handler and pin its behaviour before the PATCH restructure changes it — characterization tests, not documentation | [`API-COVERAGE.md`](API-COVERAGE.md) → *`updateDepartment` was the weak spot*; [`TESTING.md`](TESTING.md) → *Step 5* is the method | [#33](https://github.com/sequeiralabs/foobar/pull/33) |
| 9 | Add `/employees/{employeeId}` — GET, PATCH and DELETE | Three handlers plus `UpdateEmployeeRequest`; `required` dropped from `UpdateDepartmentRequest` so both resources agree on what `PATCH` means. Phase 1 complete — both entities have full CRUD. 30 tests, up from 21 | [`API-DESIGN.md`](API-DESIGN.md) → *Where the API stands* and §1.3; [`API-COVERAGE.md`](API-COVERAGE.md) → the merge that no test pins | [#38](https://github.com/sequeiralabs/foobar/pull/38) |
| 19, 20 | What `DELETE /departments/{id}` does with employees; is a department required | **Required `@Parent`**, and **restrict on delete enforced twice** — a pre-check for the message, `.restrict` on the foreign key for the race. No code; #18 inherits the work, and #21 folds into it | [`API-DESIGN.md`](API-DESIGN.md) §2.4 and §2.5 — including why requiring the column retires §1.3's deferred absent-vs-null cost | [#40](https://github.com/sequeiralabs/foobar/pull/40) |
| 11 | Two `401` declarations describe authentication that does not exist | Both blocks deleted from `openapi.yaml`, plus the handler comments that referenced them. The spec now declares only responses the server can produce, so declared-response coverage reads 20 of 20 | [`API-COVERAGE.md`](API-COVERAGE.md) → *The two `401`s*; the design survives on #24 and in [`MIDDLEWARE.md`](MIDDLEWARE.md) | [#46](https://github.com/sequeiralabs/foobar/pull/46) |

## Findings that outlived their issue

Things learned while working an issue that belong to a *different* issue, recorded here so they are
not lost between the two.

| Found while working | Belongs to | Finding |
| --- | --- | --- |
| #1 | [#5](https://github.com/sequeiralabs/foobar/issues/5) | `configureDatabase` discards the diagnostic as well as misclassifying it. `PSQLError` has no `LocalizedError` conformance, so `localizedDescription` yields the `NSError` bridge string. PostgresNIO makes `description` deliberately generic to prevent leaking sensitive data and documents `String(reflecting:)` as the way in — which means the detail belongs in a log line, never in a response body. |
| #1 | [#37](https://github.com/sequeiralabs/foobar/issues/37) | `Tests/foobarTests/TestHelpers.swift:47` warns that the result of `configureServer` is unused. Harmless today; it would block ever enabling `--warnings-as-errors`. **Still live as of 2026-08-16** — #7 closed without touching it, and it is not formatting, so it does not belong to #6 either. SwiftPM only re-emits it when that file recompiles, which is why it is easy to believe it has gone away. Filed 2026-08-16, to be done alongside #36. |
| #1 | [#28](https://github.com/sequeiralabs/foobar/issues/28) | Branch protection is unavailable on private repositories on the Free plan — both the rulesets and classic protection APIs return 403. So `main` is currently protected by routine rather than by a rule, and closing that gap is a decision (publish, pay, or accept) before it is a task. |
| #1 | [#30](https://github.com/sequeiralabs/foobar/issues/30) | The cold CI compile is **682s** of a ~12 minute run, roughly 7× the same build locally, on a 2-core runner. `.build` caching was deliberately left out of #1 to avoid stale-module corruption; with a baseline now measured, a cache keyed on the **toolchain version** as well as `Package.resolved` is worth its own issue. Filed 2026-08-15. |
| #7 | [#9](https://github.com/sequeiralabs/foobar/issues/9) | The comment above `createEmployee` still describes department behaviour. Left alone rather than fixed in passing, because #7 was a behaviour-preserving refactor whose whole proof was an empty `git diff --ignore-all-space` — one prose edit would have destroyed that proof for no gain. Folded into #9, which rewrites those handlers anyway. |
| #8 | [#9](https://github.com/sequeiralabs/foobar/issues/9) | The three new employee handlers get their model → schema conversion for free from `SchemaConversions.swift`. Use `try Components.Schemas.Employee(model)`; do not reintroduce a local unwrap. |
| #10 | [#9](https://github.com/sequeiralabs/foobar/issues/9) | Making `name` optional in `UpdateDepartmentRequest` means the uniqueness pre-check in `updateDepartment` must run only when a name is actually present — otherwise a body that omits `name` queries for `nil`. |
| #13 | [#17](https://github.com/sequeiralabs/foobar/issues/17) | **The `409` tests cannot tell which code path produced the conflict.** Deleting the entire pre-check from `updateDepartment` leaves all 21 tests passing, because the unique index then rejects the `save` and the `catch` returns the same `409`. So neither path is individually pinned, and the pre-check — whose only job is to answer cleanly without a failed transaction — is deletable without any test noticing. Distinguishing them needs either a rollback counter (the method already used for the constraint-violation work) or different response prose, which would be a behaviour change. |
| #10 | not yet filed | **Issue #9's body was overwritten**, not appended to, when the stale-comment note was folded into it on 2026-08-15 — the original description and the blocked-by line were lost and went unnoticed until this issue needed to edit it. Reconstructed from `API-DESIGN.md` §1.1 and the house style of #11 and #18; a scan of all 40 issues found no other casualty. `gh issue edit --body-file` **replaces** the body. Read it first and include the existing text, or use `gh issue comment`. |
| #9 | [#17](https://github.com/sequeiralabs/foobar/issues/17) | **Second instance of the indistinguishable-409 problem.** `updateEmployee`'s pre-check must merge supplied fields with stored ones; breaking that merge leaves all 30 tests green, because the unique index rejects the save and the `catch` returns an identical `409`. As in #13, the outcome is pinned but the path to it is not — a bug there silently degrades a clean pre-check into a failed transaction. |
