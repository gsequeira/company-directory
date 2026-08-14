# Working an issue

The routine for taking one issue from open to merged: whether it needs a branch, what to call it,
and what "done" means for each kind of issue.

**Written 2026-08-14**, when the backlog moved from prose in `Docs/` into GitHub Issues.

Outstanding work lives in **GitHub Issues** on `sequeiralabs/foobar`; this repository's `Docs/`
hold the reasoning. Read the doc for *why*, the issue for *whether it is done*, and do not copy
prose between them — that is how one of them goes quietly stale.

## The short version

```bash
gh issue develop 3 --checkout          # branch, linked to the issue on GitHub
docker compose up -d --wait            # the suite needs db-test running
# ... work ...
swift build && swift test              # 14/14 before you push
git push -u origin HEAD
gh pr create --fill --body "Fixes #3"
```

Squash-merge, then delete the branch.

---

# Should this one have a branch?

**Default to yes.** Deciding per-change costs more thought than it saves, and the failure mode is
asymmetric — you only find out a change was not trivial *after* it turns out not to be.

The case is already proved in this repository. During the PostgreSQL migration, commit `8855317`
left the build deliberately broken for two commits while the driver swap landed ahead of the code
that used it. That is fine on a branch and unacceptable on `main`. When the Postgres 18 volume path
and then an orphaned `.swiftmodule` both went wrong, `git switch main` was a working escape hatch.

**The reason gets stronger once #1 lands.** Today, solo and with no CI, a branch buys the escape
hatch and little else — there is no reviewer. Once CI runs, a pull request is where the checks run
*before* `main` is affected rather than after. Add a branch protection rule requiring the check and
`main` stops being breakable by accident.

## Where going straight to `main` is defensible

Small, self-contained, fully covered by the existing suite, and green before you commit:

| Issue | Why it qualifies |
| --- | --- |
| #3 | Two lines, `.sort()` on both list handlers |
| #4 | One `asyncShutdown()` call on the success path |
| #7 | Deleting no-op `do/catch` blocks; behaviour cannot change |

Even here, a branch costs about fifteen seconds. The table exists so the judgement is explicit, not
to encourage using it.

## Where a branch is not optional

- **#1 (CI)** — the workflow file needs iterating against the runner, and early attempts fail.
  Never on `main`.
- **#2 (error middleware)** — touches every endpoint's behaviour, and lands with new tests.
- **#6 (swift-format)** — `--in-place` touches nearly every line. Its own branch *and* its own
  commit, never mixed with a behavioural change, or the diff becomes unreviewable.
- **#9 (employee CRUD)** — adding operations to the spec breaks the build until `APIHandler`
  implements them. Deliberately broken in between.
- **#18 (the relationship)** — a migration, model changes and spec changes together.

---

# Naming

`gh issue develop` derives the branch from the issue title and registers it as a **linked branch**
on GitHub, so the issue page shows the connection. That linkage is the reason to prefer it over
`git switch -c`.

```bash
gh issue develop 18 --checkout
# → 18-add-the-department-to-employee-one-to-many-relationship
```

Long, but it sorts by issue number and you never have to invent one. When the derived name is
unwieldy, override it while keeping the number prefix:

```bash
gh issue develop 18 --checkout --name 18-department-employee-relationship
```

**The convention is `<issue-number>-<short-slug>`.** The number is the part that matters — it ties
the branch to the issue, the PR and the commit without anyone having to remember what "the FK work"
referred to.

Suggested short names where the derived one is too long:

| Issue | Branch |
| --- | --- |
| #1 | `1-ci-workflow` |
| #2 | `2-error-middleware-400` |
| #3 | `3-sort-list-endpoints` |
| #5 | `5-migration-error-classification` |
| #6 | `6-swift-format` |
| #8 | `8-remove-force-unwraps` |
| #9 | `9-employee-crud` |
| #11 | `11-remove-401-declarations` |
| #14 | `14-invalid-input-tests` |
| #17 | `17-constraint-violation-test` |
| #18 | `18-department-employee-relationship` |
| #21 | `21-narrow-constraint-mapping` |

---

# Order

Most issues are independent. Six carry a dependency note in the issue body itself; those are the
ones to respect:

| Do first | Before | Why |
| --- | --- | --- |
| #2 | #14 | The invalid-input tests land red until the `400` mapping exists |
| #3 | Any new list-asserting test | Current ordering is accidental; write tests against it and the luck gets baked into assertions |
| #10 | #9 | `UpdateEmployeeRequest`'s shape *is* the PATCH decision |
| #19, #20 | #18 | Both change the migration and the model |
| #17 | #18 | Phase 2 changes that code's correctness — the test turns it into a visible failure |
| #18 | #21 | Nothing to narrow until the foreign key exists |

**Coverage work last**, deliberately: Phase 2 changes the `Employee` schema, so employee tests
written before it get rewritten. #13 is the exception — department-only, so Phase 2 cannot
invalidate it.

Suggested first three, all cheap and independent: **#1**, then **#2**, then **#3**.

---

# What "done" means

It differs by label, and getting this wrong is how an issue gets closed while the problem survives.

## `decision`

Produces **no code**. Done when the decision and its reasoning are written into
[`API-DESIGN.md`](API-DESIGN.md), replacing the open question rather than sitting alongside it.

Record what was rejected and why — §1.2 is the worked example, where the outcome went against the
recommendation on file and the doc says so. Then open or unblock the implementation issue, which is
separate work.

## `spec-defect`

1. Change `Sources/foobar/openapi.yaml`.
2. Build. If `APIProtocol` gained requirements, the compiler now enumerates the work — that is
   spec-first behaving correctly, not a problem.
3. Implement, and add tests for the new responses.

## `implementation-defect`

**Prove it was broken first.** Write the failing test, or reproduce by hand and record the output
in the issue, before the fix. Otherwise you cannot tell a fix from a coincidence.

The constraint-violation mapping is the standard to match: verified in both directions, `409` with
the fix and `500` without it, with a rollback counter proving the database was actually reached.
See [`MIGRATIONS.md`](MIGRATIONS.md) → *Forcing the race deterministically*.

## `test-gap`

Add the test, then **confirm it can fail** — break the code deliberately and watch it go red. An
assertion that passes for the wrong reason reports coverage you do not have, and this suite has
already shipped one. [`TESTING.md`](TESTING.md) step 5.

## `tooling`

Its own commit, never mixed with behaviour. A change that touches every file should not share a
commit with a change that means something.

## `deferred`

Closing means either doing it or deciding not to. "Not now" is the state it is already in — leave
it open.

---

# Checklist

Before opening the pull request:

- [ ] Branch named `<issue-number>-<slug>`, created with `gh issue develop` so it is linked.
- [ ] `docker compose up -d --wait` — the suite needs `db-test`.
- [ ] `swift build` clean. Warnings count.
- [ ] `swift test` — 14/14, or more if the issue added tests.
- [ ] New behaviour has a test, and that test has been seen to fail.
- [ ] Docs updated where the change contradicts them. A stale doc is worse than a missing one.
- [ ] Tooling changes are in their own commit.
- [ ] PR body says `Fixes #N`, so merging closes the issue.

After merging:

- [ ] Squash-merge, delete the branch.
- [ ] `git switch main && git pull`.
- [ ] Check whether the issue unblocked another — the dependency notes cut both ways.
