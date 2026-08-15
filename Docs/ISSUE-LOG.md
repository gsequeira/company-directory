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
| 1 | Add CI to run the test suite on push | `.github/workflows/ci.yml` — Linux job on `swift:6.3.3` with PostgreSQL 18 as a service container, 14/14 green on amd64 | [`WORKFLOW.md`](WORKFLOW.md) → *Where the checks run*; [`POSTGRES.md`](POSTGRES.md) → *What this unlocks* | [#27](https://github.com/sequeiralabs/foobar/pull/27) |

## Findings that outlived their issue

Things learned while working an issue that belong to a *different* issue, recorded here so they are
not lost between the two.

| Found while working | Belongs to | Finding |
| --- | --- | --- |
| #1 | [#5](https://github.com/sequeiralabs/foobar/issues/5) | `configureDatabase` discards the diagnostic as well as misclassifying it. `PSQLError` has no `LocalizedError` conformance, so `localizedDescription` yields the `NSError` bridge string. PostgresNIO makes `description` deliberately generic to prevent leaking sensitive data and documents `String(reflecting:)` as the way in — which means the detail belongs in a log line, never in a response body. |
| #1 | #6 or #7 | `Tests/foobarTests/TestHelpers.swift:47` warns that the result of `configureServer` is unused. Harmless today; it would block ever enabling `--warnings-as-errors`. |
| #1 | not yet filed | The cold CI compile is **682s** of a ~12 minute run, roughly 7× the same build locally, on a 2-core runner. `.build` caching was deliberately left out of #1 to avoid stale-module corruption; with a baseline now measured, a cache keyed on the **toolchain version** as well as `Package.resolved` is worth its own issue. |
