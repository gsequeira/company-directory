# Working an issue

The routine for taking one issue from open to merged: whether it needs a branch, what to call it,
and what "done" means for each kind of issue.

**Written 2026-08-14**, when the backlog moved from prose in `Docs/` into GitHub Issues.

Outstanding work lives in **GitHub Issues** on `sequeiralabs/foobar`; this repository's `Docs/`
hold the reasoning. Read the doc for *why*, the issue for *whether it is done*, and do not copy
prose between them — that is how one of them goes quietly stale.
[`ISSUE-LOG.md`](ISSUE-LOG.md) is the index of what has been finished and which document absorbed
each lesson.

## The short version

```bash
gh issue develop 3 --checkout          # branch, linked to the issue on GitHub
docker compose up -d --wait            # the suite needs db-test running
# ... work ...
swift format lint --strict -r Sources Tests Package.swift   # CI gates on this
swift build && swift test              # all green before you push
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

**The reason got stronger when #1 landed.** Solo and with no CI, a branch bought the escape hatch
and little else — there is no reviewer. Now that CI runs, a pull request is where the checks run
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

## Adding to an issue body

`gh issue edit --body` and `--body-file` **replace** the body — they do not append. Adding a note
therefore means reading the current body, editing the whole thing, and writing it back:

```bash
gh issue view 9 --json body -q .body > /tmp/issue9.md   # existing text first
# append the note, then:
gh issue edit 9 --body-file /tmp/issue9.md
```

Write the body to a file rather than passing `--body "…"`; a body containing backticks and quotes
will otherwise be mangled by the shell before `gh` ever sees it.

**This has already cost once.** #9's original description was silently destroyed on 2026-08-15 by an
edit that supplied only the new note, and the loss was found a day later by accident. If the note
stands on its own, `gh issue comment` cannot lose anything and is the safer default.

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

## The linked branch closes the issue, whatever the pull request says

A linked branch is not only a display convenience. **When a pull request from that branch merges,
GitHub closes the linked issue** — closing keywords are not consulted, and no wording in the pull
request can prevent it.

This has already cost once. #18 is three steps in three pull requests; the first said in its body,
in bold, *"Part of #18 — step 1 of 3. Does not close it."* Merging it closed #18 anyway, and the
issue timeline shows `connected` followed by `closed`. It went unnoticed until the issue counts were
checked by hand a few hours later.

**So for an issue that takes more than one pull request, do not use `gh issue develop`.** Create the
branch directly, keeping the number in the name so the convention still holds:

```bash
git switch -c 18b-employee-department-model
```

Reference the issue in the body — `Part of #18` — and let the final pull request be the one that
finishes it, with a closing keyword. The linkage is worth having when one branch completes an issue,
and is actively wrong when it does not.

### A second mechanism: prose in a commit message

The commit recording the incident above contained the sentence *"Merging it closed #18 anyway"*.
GitHub matched `closed #18` as a closing keyword and closed the issue for a second time, within a
minute of it being reopened.

**Any of `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`
immediately before `#N` will close that issue**, wherever it appears in a commit message or pull
request body — including inside a sentence that is merely describing something. Write "issue 18" or
rephrase the verb when the intent is narrative rather than instruction.

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

Most issues are independent. Those that are not carry a dependency note in the issue body itself;
those are the ones to respect:

| Do first | Before | Why |
| --- | --- | --- |
| #14 | #2 | **Reversed 2026-08-16.** The invalid-input tests used to be blocked on the `400` mapping. Written inside `withKnownIssue` they land green now and fail when #2 fixes the defect — so they are #2's acceptance criteria. See [`TESTING.md`](TESTING.md) → *Step 7* |
| #3 | Any new list-asserting test | Current ordering is accidental; write tests against it and the luck gets baked into assertions |
| ~~#10~~ | #9 | `UpdateEmployeeRequest`'s shape *is* the PATCH decision. **Decided 2026-08-16** — partial update; see [`API-DESIGN.md`](API-DESIGN.md) §1.3. #9 is unblocked, and also carries the matching change to `UpdateDepartmentRequest` |
| ~~#7, #8~~ | #9 | #9 mirrors the department handlers. Copy them unfixed and it is six sites to correct, not three. **Both merged** 2026-08-15/16 |
| ~~#19, #20~~ | #18 | Both change the migration and the model. **Decided 2026-08-16** — required `@Parent`, and restrict on delete; see [`API-DESIGN.md`](API-DESIGN.md) §2.4 and §2.5 |
| #17 | #18 | Phase 2 changes that code's correctness — the test turns it into a visible failure |
| #18 | ~~#21~~ | **Folded into #18 on 2026-08-16.** Nothing to narrow until the foreign key exists — but shipping the foreign key *without* narrowing leaves four `catch` blocks able to report a duplicate name that does not exist. Doing it separately means merging a known-wrong error path |

Two of these are cost dependencies rather than hard ones — #7 and #8 before #9, and declaring `400`
on the new operations while #9's spec is open rather than making #2 retrofit six of them. Nothing
breaks if they are ignored; the same work simply gets done twice.

**#6 is a scheduling constraint, not an ordering one.** `swift format --in-place` touches nearly
every line, so it conflicts with any large branch that is open at the time. Run it on a quiet tree
— before starting Phase 1, or after Phase 2 merges. Not in between.

**Coverage work last**, deliberately: Phase 2 changes the `Employee` schema, so employee tests
written before it get rewritten. #13 is the exception — department-only, so Phase 2 cannot
invalidate it.

**Phase 1 is complete** as of 2026-08-16: #1, #7, #8, #9, #10, #13, #16 and #34 are merged, and
both entities have full CRUD. **Next is #18**, the relationship, with #19, #20 and #21 folded in.

---

# Where the checks run

Three layers, each catching something the one before it cannot. They are not redundant, and the
point is not to make any of them stop finding things.

| Layer | Command | Cost | Catches |
| --- | --- | --- | --- |
| macOS, every change | `swift test` | ~0.7s warm | Everything ordinary |
| Linux container, when the risk surface moves | see below | 92s cold, 1–9s warm | Glibc and Foundation divergence, conditional imports, filesystem and process APIs |
| CI, every push | automatic | minutes | All of the above, in a clean environment, on the record |
| A running server, by hand | `Scripts/smoke.sh`, or `SMOKE_BASE_URL=… swift test --filter SmokeTests` | ~5s | A real socket, `/health`, and migrations against a database that already has rows — none of which the suite touches. The Swift version additionally decodes into the generated types, so a spec change breaks it at compile time |

[`CI.md`](CI.md) is the playbook for the third layer: how to watch a run, read a failure, reproduce
it locally, and what goes wrong.

## The middle layer

You can run the Linux check without waiting on GitHub:

```bash
docker compose up -d --wait db-test
docker run --rm --network foobar_default \
  -e TEST_DATABASE_HOST=db-test -e TEST_DATABASE_PORT=5432 \
  -v "$PWD":/src -w /src -v /tmp/company-directory-linux-build:/build \
  swift:6.3.3 swift test --scratch-path /build
```

Two details carry the weight:

- **`--scratch-path` is not tidiness.** Without it the container writes Linux modules into your
  macOS `.build`, which is the corruption in [`TOOLCHAIN.md`](TOOLCHAIN.md) with an extra
  dimension added. Point it at a directory outside the repository.
- **`--network foobar_default`** puts the build container on the same network as the compose
  services, so `db-test:5432` resolves — the *container* port, not the published 5433. That is
  structurally identical to what a GitHub service container provides, which makes this the honest
  rehearsal for CI rather than an approximation of it.

Measured on this project: 92s for the first build, then 1–9s while the scratch path persists. So
this is not the slow fallback it sounds like — but do not run it on every commit. It catches a
class of problem that fires rarely, and paying 92s for it routinely is how the habit dies. Run it
when you add a dependency, touch Foundation, filesystem, process or date APIs, or bump the
toolchain.

## Why there is no pre-push hook

A hook running `swift test` before every push is the obvious next idea, and it is a trap here.

**The suite depends on external state.** It needs the `db-test` container running. That was
demonstrated accidentally while setting up #1: the container stopped between two runs and the next
run produced 14 failures, every one of them `SocketAddressError.UnknownHost … for host db-test`.
Nothing was wrong with the code. A hook would have blocked that push for a reason unrelated to the
change, and `git push --no-verify` becomes muscle memory after about the second time — leaving a
hook that blocks nothing and a habit of stepping around safety checks.

**`.git/hooks` is not versioned.** It is invisible machine-local behaviour, so the guarantee
silently does not exist on a second machine or for anyone else.

**Branching already covers it.** A bad push lands on a branch, CI goes red, `main` is untouched.
The hook defends a door that is already locked.

The argument *for* a hook is usually that CI should be reserved for Linux and reproducibility
rather than "catching things you would have caught anyway". That inverts the point. CI catching
something you could have caught locally is the redundancy working; its value is being unskippable
and visible, and a hook is neither. If you want automation, prefer an explicit committed
`scripts/check`, or a **pre-commit** hook running only sub-second checks such as
`swift format lint`, managed by a versioned runner rather than raw `.git/hooks` — and not before
#6 has cleared its findings.

---

# Verifying a change that should not change behaviour

Some issues are mechanical: a reformat (#6), removing dead syntax (#7), a rename. They share a
shape — a large diff that is supposed to alter nothing — and that shape defeats the usual checks.

**A green suite is weak evidence here.** 14 tests do not exercise every path, so "tests pass" means
"nothing covered broke". For a change touching 200 lines across seven functions, that is a much
smaller claim than it sounds. The instinct to treat a green run as proof is strongest exactly when
the change is boring, which is when it is least justified.

**Prefer a check whose failure would be visible.** For anything that only moves whitespace:

```bash
git diff --ignore-all-space
```

If the transformation really is structural, that diff contains *only* the lines you meant to
delete. Anything else appearing is something you changed without noticing. It converts "trust me,
it is just re-indentation" into a one-command verification, and it takes a second.

Related tools for the neighbouring cases:

| Change | Check |
| --- | --- |
| Whitespace and indentation only | `git diff --ignore-all-space` shows only intended deletions |
| A rename | `git diff --word-diff` — every hunk should be the old and new name, nothing else |
| Reformat by a tool | Run the tool twice; the second run must produce no diff. A formatter that is not idempotent is a bug you want to find before CI does |
| Anything else | Say plainly what evidence you have. "It compiles and the tests pass" is an honest claim; it is not the same as "behaviour is unchanged" |

**One concern per pull request.** Not tidiness — diagnostics. If a mechanical change and a
behavioural one land together and something breaks, the diff cannot tell you which caused it, and
`git bisect` lands on a commit that did two things. The cost of splitting is a second branch and
about fifteen seconds.

**Watch for issues that collide in the same file.** #6, #7 and #8 all rewrite `APIHandler.swift`,
and two of them rewrite its indentation. They are independent as *issues* and adjacent as *diffs*.
Sequence them, never interleave, and re-measure any counts recorded in an issue body afterwards —
#6's finding count changes the moment #7 lands.

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

1. Change `Sources/CompanyDirectory/openapi.yaml`.
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

# Numbers rot, records do not

A sweep of all twelve documents on 2026-08-16 found the prose sound and every cross-reference
resolving. The only drift was of one kind, in four places: **a count written into an instruction**.

```bash
swift test              # 14/14 before you push      ← wrong after every merge that adds a test
swift test              # all green before you push  ← still true in a year
```

The distinction that matters is between an **instruction** and a **record**.

| Kind | Example | Numbers? |
| --- | --- | --- |
| Instruction — something a reader will run | the checklist below, `POSTGRES.md` Step 0 | **No.** Say what good looks like, not how many |
| Record — what happened at a moment | "14/14 green on amd64" in [`ISSUE-LOG.md`](ISSUE-LOG.md), the outputs in `POSTGRES.md` | **Yes.** The number *is* the evidence, and history does not go stale |

[`API-COVERAGE.md`](API-COVERAGE.md) shows the third case, and gets it right: a status document
that will certainly go out of date, stamped with its date and commit and saying so in its own
opening. That is the honest way to write a number that ages — not to avoid it, but to date it.

The same rule caught a stale code quote in the same sweep: `API-COVERAGE.md` still quoted
`existingDepartment.id!` after #8 replaced it with `requireID()`. Quoting source in prose is a
record of the code at a moment, so it drifts the same way. Prefer a file-and-symbol reference over a
paste when the exact text does not carry the point.

---

# Checklist

Before opening the pull request:

- [ ] Branch named `<issue-number>-<slug>`, created with `gh issue develop` so it is linked.
- [ ] `docker compose up -d --wait` — the suite needs `db-test`.
- [ ] `swift build` clean. Warnings count.
- [ ] `swift test` — every test passing, and the count higher than before if the issue added any.
- [ ] New behaviour has a test, and that test has been seen to fail.
- [ ] Docs updated where the change contradicts them. A stale doc is worse than a missing one.
- [ ] No test count written into an instruction — see *Numbers rot, records do not* below.
- [ ] If a response declaration changed in `openapi.yaml`, the handler's `///` comment changed with
      it. They restate the spec deliberately; the spec stays the source of truth.
- [ ] Tooling changes are in their own commit.
- [ ] PR body says `Fixes #N`, so merging closes the issue.

After merging:

- [ ] Squash-merge, delete the branch.
- [ ] `git switch main && git pull`.
- [ ] Add a row to [`ISSUE-LOG.md`](ISSUE-LOG.md). A row, not a paragraph — if it wants to be a
      paragraph, that belongs in the topic document and the row should link to it.
- [ ] Anything learned that belongs to a *different* issue: comment on that issue, and log it under
      *Findings that outlived their issue*. This is where most knowledge gets lost.
- [ ] Check whether the issue unblocked another — the dependency notes cut both ways.
