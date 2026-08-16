# Continuous integration

What CI is, why this project has it, how to drive it, and the ways it goes wrong.

**Written 2026-08-15**, when `.github/workflows/ci.yml` landed via issue #1.

Companion documents: [`WORKFLOW.md`](WORKFLOW.md) → *Where the checks run* covers the three layers
of checking and where CI sits among them; [`POSTGRES.md`](POSTGRES.md) explains the database this
job starts; [`TOOLCHAIN.md`](TOOLCHAIN.md) explains the pinned Swift version.

---

# Part 1 — What CI is and why bother

## The idea

Continuous integration is one promise: **every change is built and tested in a known-clean
environment, automatically, with the result attached to the change.**

Each clause is doing work.

- **Every change** — not the ones you remembered. Discipline you have to sustain is discipline that
  eventually lapses, usually on the day you are in a hurry, which is also the day you are most
  likely to break something.
- **Known-clean environment** — a fresh container with nothing cached from yesterday, no
  half-finished experiment, no locally-installed tool that only you have. If it passes there, it
  passes for a stranger.
- **Automatically** — no step a human can skip.
- **Attached to the change** — the result lives on the pull request. Six months later you can see
  that this commit was green when it merged, without re-running anything.

## Why this project needs it

Four specific reasons, not general principle.

**The tests only ran when remembered.** There were 14 tests and nothing that ran them. A test suite
nobody runs is documentation of intent, not a safety net.

**Linux was completely unverified.** Everything here had only ever been compiled on macOS, while
nothing in the project guaranteed it worked anywhere else. That gap was invisible precisely because
it never got tested. It turned out fine — but "turned out fine" was not knowledge until something
checked.

**There is no reviewer.** On a solo project CI is the only second opinion available. It cannot
judge design, but it can say *this does not build* and *this test now fails*, which is most of what
review catches mechanically.

**It makes `main` protectable.** This is the real prize. A green check is informational; a green
check that a branch protection rule *requires* means `main` cannot be broken by accident, including
by you at midnight. See *Turning the check into a gate* below.

## What CI is not

Worth being precise, because over-trusting CI is its own failure mode.

- **Not a replacement for running tests locally.** Local is 0.7s; CI is twelve minutes. Use the
  fast loop for work and the slow one for proof.
- **Not proof of correctness.** It runs the tests you wrote. A green check on a suite that does not
  cover malformed input — as this one currently does not; see
  [`API-COVERAGE.md`](API-COVERAGE.md) — proves only that the uncovered defect did not get worse.
- **Not a deployment pipeline.** This workflow builds and tests. Nothing here ships anything.

## When CI is not worth it

For a throwaway spike, a scratch repository, or a project with no tests, a green badge is theatre —
it costs setup time and minutes to tell you nothing. CI earns its place when there is a real suite
to run and more than one environment to worry about. Both were true here; neither was true a month
ago.

---

# Part 2 — The play

The workflow runs itself. What follows is what *you* do.

## When it fires

```yaml
on:
  push:
    branches: [main]
  pull_request:
```

`pull_request` covers everything on its way to `main`; `push` covers `main` itself after a merge.
The `branches: [main]` filter on `push` is what stops a push to a PR branch triggering both events
and running the same job twice for one change.

## The normal loop

```bash
gh issue develop 3 --checkout            # branch, linked to the issue
docker compose up -d --wait              # the suite needs db-test
# ... work ...
swift format lint --strict -r Sources Tests Package.swift   # CI gates on this too
swift build && swift test                # green locally first
git push -u origin HEAD
gh pr create --fill --body "Fixes #3"    # opening the PR triggers CI
```

Then watch it:

```bash
gh pr checks 27                    # one line per check on the PR
gh run list --branch <branch>      # recent runs
gh run watch <run-id>              # live, blocks until finished
gh run view <run-id>               # step-by-step summary
```

## Reading a failure

Start with the step list, which tells you *which* step failed before you read any log:

```bash
gh run view --job=<job-id>
```

Then the log, filtered — the full log is thousands of lines of compiler progress:

```bash
gh run view --log --job=<job-id> | grep -E "error:|Test run with|✘"
```

`✘` marks a failing test in Swift Testing output; `error:` marks a compile failure. If neither
appears, the failure is in the harness rather than the code — a service container that never became
healthy, or a step script that exited non-zero.

## Re-running

```bash
gh run rerun <run-id>              # everything
gh run rerun <run-id> --failed     # only the failed jobs
```

**Be honest about why you are re-running.** A rerun is legitimate when the failure was
environmental — a runner timeout, a registry hiccup. Re-running until it goes green is how a real
intermittent bug becomes permanent: the evidence is discarded each time. If a rerun fixes it,
write down what you think was flaky, because a suite that fails one run in ten is a defect with a
long fuse.

## Reproducing a CI failure locally

The whole point of the container job is that you can run the same thing on your machine. See
[`WORKFLOW.md`](WORKFLOW.md) → *Where the checks run* for the full recipe:

```bash
docker compose up -d --wait db-test
docker run --rm --network company-directory_default \
  -e TEST_DATABASE_HOST=db-test -e TEST_DATABASE_PORT=5432 \
  -v "$PWD":/src -w /src -v /tmp/company-directory-linux-build:/build \
  swift:6.3.3 swift test --scratch-path /build
```

Same toolchain, same Linux, same service-container topology. 92s cold, then 1–9s.

## Turning the check into a gate

Until a branch protection rule requires it, CI only reports. To make it binding, add a rule on
`main` requiring the **Build and test (Linux)** check — the job's `name:`, not the workflow's.
Rename the job and the rule silently stops matching, which looks exactly like a repository with no
protection at all.

**Not done, and blocked on the account plan rather than on configuration.** Attempted 2026-08-15;
both APIs refuse:

```
GET /repos/sequeiralabs/foobar/rulesets                   403
GET /repos/sequeiralabs/foobar/branches/main/protection   403
"Upgrade to GitHub Pro or make this repository public to enable this feature."
```

Branch protection and rulesets are unavailable on **private** repositories on the Free plan, so
this is a decision — pay, publish, or accept it — before it is a task. Tracked as issue #28, which
also records the settings worth getting right when the time comes, including why required
approvals must be **0** on a solo repository: GitHub does not let you approve your own pull
request, so any other value makes merging impossible.

**Decided 2026-08-15: stay private on the Free plan and leave `main` unprotected.** Pro would buy
exactly one thing here — protection on a private repository — and the usage figures below show it
buys nothing on minutes or storage. Revisit when a second contributor appears, since "the routine
protects `main`" only ever protected it from *your own* mistakes.

**Current state, therefore: CI reports and does not gate.** The practical loss is smaller than it
sounds here, because [`WORKFLOW.md`](WORKFLOW.md) already routes work through a pull request — you
would have to override your own documented routine to break `main`. It is worth knowing that is
what protects the branch today, rather than assuming a rule does.

---

# Part 3 — Anatomy of the workflow

```yaml
container: swift:6.3.3
```

The job runs *inside* the official Swift image. That image is the swift.org toolchain — the same
distribution swiftly installs locally ([`TOOLCHAIN.md`](TOOLCHAIN.md)) — so nothing is downloaded
or unpacked at run time.

```yaml
services:
  postgres:
    image: postgres:18-alpine
```

Actions starts this alongside the job container on a shared network and health-gates the job on it.

```yaml
env:
  TEST_DATABASE_HOST: postgres
  TEST_DATABASE_PORT: 5432
```

**The service name is the hostname, and the port is the container's port.** There is no `ports:`
mapping and none is wanted. `ports:` plus `localhost` is what a job running directly on the runner
needs; the two configurations are not interchangeable and mixing them is the most common way this
fails.

The database *name* is not here because it is deliberately not overridable — `company_directory_test` is
hardcoded in `TestHelpers`, so a misconfiguration fails to connect rather than reaching a database
whose tables `autoRevert()` would then drop.

---

# Part 4 — What can go wrong

## In the workflow itself

| Symptom | Cause | Fix |
| --- | --- | --- |
| Step *Check formatting* fails | The tree was not formatted before pushing | Run `swift format --in-place -r Sources Tests Package.swift`, commit, push. The formatter is idempotent, so running it is always safe |
| Step *Verify the toolchain* fails with "Toolchain drift" | `.swift-version` was bumped and the `container:` tag was not | Update the tag in `ci.yml` to match. The error message names the file |
| `swift: not found`, or the build fails immediately | Someone changed the image to a `-slim` tag | Slim variants ship the runtime only, with no compiler. Use the plain tag |
| Job never starts, hangs at *Initialize containers* | The service container never reported healthy | Check the `--health-cmd`. `pg_isready` must name a user and database that exist |
| `SocketAddressError.UnknownHost for host …` | Wrong hostname — `localhost` instead of the service name | In a `container:` job the service is reached by name, not `localhost` |
| Connection refused on 5433 | Copied the host port from `docker-compose.yml` | Inside CI it is the container port, **5432**. 5433 only exists on your Mac |
| Job cancelled at the timeout | Cold compile plus a slow runner | Baseline is 682s of compile in a ~12 minute run; the limit is 30 minutes. If this fires routinely, cache `.build` rather than raising it again |
| Deprecation annotation about Node | The pinned action major targets an old Node | Bump the action major. Checked on 2026-08-15: `checkout@v7`, `cache@v6` |
| Everything is green but nothing ran | A `paths-ignore` filter matched the whole change | See the trap below |

## The `paths-ignore` trap

Skipping CI for documentation-only changes looks obviously correct, and it deadlocks a protected
branch: if the check is **required** and the workflow is skipped, the check never reports, so the
PR can never merge. The safe pattern is a job that always runs and passes trivially for ignored
paths, rather than skipping the workflow. Not worth doing here yet — but decide it before adding
branch protection, not after.

## In the tests

| Symptom | Cause |
| --- | --- |
| Tests interfere, results change with ordering | The `.serialized` trait on the suite was removed. The PostgreSQL server is *shared* by every test — unlike the old in-memory SQLite, isolation now comes from serialization plus `autoRevert()`, and removing either breaks it |
| Passes locally, fails in CI | Usually leftover local state. CI starts from an empty database every time; your `db-test` container does not |
| Passes in CI, fails locally | Almost always a stopped `db-test` container. Check `docker compose ps` before assuming it is your code |

## Green in CI, will not build on your Mac

The reverse of the row above, and not a CI fault: the pinned toolchain can be older than the macOS
SDK on a *local* machine, which on a beta OS breaks the build inside a dependency while CI stays
green. The job runs in `swift:6.3.3` on Linux and never sees a macOS SDK, so the failure cannot
reach it — the environment CI standardises is exactly the one that diverged.

Recorded 2026-08-16 with the full error, the three fixes not to reach for, and the local override
that leaves `.swift-version` alone: [`TOOLCHAIN.md`](TOOLCHAIN.md) → *A beta macOS SDK can outrun
the pin*. The rule for this document is the short one — **do not "fix" it by editing
`.swift-version` or the `container:` tag**, which would break every machine that was working.

## Cached-build corruption

`.build` is **deliberately not cached**. A build directory written by a different compiler produces:

```
compiled module was created by a newer version of the compiler
```

This project has already paid for that once locally, when two Swift 6.3.3 toolchains wrote into the
same directory ([`TOOLCHAIN.md`](TOOLCHAIN.md)). It is far worse in CI, where you cannot poke at the
directory to find out. If `.build` caching is added later, the cache key **must include the
toolchain version**, not just `Package.resolved` — otherwise a toolchain bump silently restores
incompatible modules and the failure looks like a compiler bug.

## Cost and quota

This repository is **private on the Free plan**, so Actions minutes are metered rather than
free-for-public. A run is roughly twelve minutes on a 2-core Linux runner, nearly all of it one
cold compile — about seven times what the same build takes locally. Linux bills at 1×; macOS
runners bill at **10×**, which is a second reason this job is not on one.

Measured 2026-08-15, after the six runs it took to land #1:

| Resource | Measured | Free allowance |
| --- | --- | --- |
| Minutes | ~13 billed per full run; ~45 for all of #1 | 2,000 / month |
| Artifacts | none — this workflow uploads nothing | 500 MB shared with logs |
| Logs | 135 KB compressed per run | as above |
| Actions cache | 413 MB | **10 GB, a separate allowance** |

Neither limit is close. The whole 26-issue backlog is projected at 900–1,000 minutes *in total*,
under half of a single month's allowance; exceeding it would take about 166 runs a month, or 5.5
every day. Filling 500 MB would take roughly 3,700 runs of logs, which expire after 90 days anyway.

**The cache figure is the one that misleads.** 413 MB looks alarming next to a 500 MB limit and is
unrelated to it: the Actions cache has its own 10 GB per-repository allowance, is free, and is
evicted least-recently-used. The 500 MB covers artifacts and logs.

Two mitigations are already in place: the `concurrency` block cancels superseded runs when you push
twice in quick succession, and only the SwiftPM dependency cache is restored. The lever in reserve
is `.build` caching, which would cut most of the 682s compile.

What would change the arithmetic: adding a build matrix (multiplies minutes directly), or uploading
artifacts such as a coverage report per run (which is what actually consumes the 500 MB).

## Security notes, for when this grows

Nothing here handles secrets yet, and that is worth preserving deliberately.

- `permissions: contents: read` is set at workflow level. The default token is broader than this
  job needs.
- The database password is `company_directory` on an ephemeral container that exists for twelve minutes and is
  reachable only from the job. It is not a secret and should never become one by being moved into
  `secrets` — that would imply it matters.
- **When a real secret does appear**, remember that `pull_request` runs from forks do not receive
  secrets by design. On a private solo repository this never arises; it is the first thing to break
  if the project ever opens up.
- `String(reflecting:)` on a `PSQLError` can contain connection parameters. Keep it in logs, never
  in a response body — see issue #5.

---

# What is next

| Item | Why | Status |
| --- | --- | --- |
| Branch protection requiring the check | Turns a report into a gate. The single highest-value follow-up | Issue #28 — blocked on the plan, not on effort |
| `.build` caching keyed on toolchain version | 682s of every run is cold compile | Not filed |
| `swift format lint --strict` step | The image already ships swift-format 6.3.3 | Waiting on #6 |
| `--warnings-as-errors` | Would currently fail on the unused-result warning in `TestHelpers.swift:47` | Blocked on that fix |

**A build matrix is deliberately absent.** Testing several Swift versions or several PostgreSQL
versions multiplies minutes by the size of the matrix, and this project pins exactly one of each on
purpose. A matrix earns its place when you genuinely support a range — a library with users on
older toolchains, say. Here it would buy nothing and cost every run.
