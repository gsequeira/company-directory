# CompanyDirectory

A spec-first CRUD API for departments and employees, in Swift.

**This is a learning project.** It exists to work through OpenAPI, Vapor, Fluent and PostgreSQL
properly rather than to be deployed, so some of what is missing is missing on purpose. Read
[What is deliberately incomplete](#what-is-deliberately-incomplete) before concluding it is broken.
`openapi.yaml` is the source of truth. The handler types are generated from it, so the compiler
enforces the contract instead of discipline.

## Getting it running

You need Docker for PostgreSQL, and Swift 6.3.3 as pinned by `.swift-version`. A bare `swift` on
macOS is often Xcode's, which is a different compiler build and breaks in confusing ways.
[`Docs/TOOLCHAIN.md`](Docs/TOOLCHAIN.md) explains how, and `swiftly install` with no argument reads
the pin. You only need [HTTPie](https://httpie.io) for the playbook and the smoke script.

```bash
git clone https://github.com/sequeiralabs/company-directory.git
cd company-directory
docker compose up -d --wait db        # PostgreSQL; migrations run at startup
swift run company-directory serve     # http://127.0.0.1:8080
```

You do not need a `.env`. The compiled defaults match `docker-compose.yml`. Then, in another
terminal:

```bash
http GET :8080/health                 # /health sits outside the OpenAPI transport, so no /api
http GET :8080/api/departments        # the list, empty until you create one
Scripts/smoke.sh                      # exercises the whole API against the running server
```

To run the suite instead, start everything with `docker compose up -d --wait`, because the tests
need the separate `db-test` service. Then `swift test`.

## Where to go next

`Docs/` holds the reasoning, in this order for a newcomer:

| Document | What it answers |
| --- | --- |
| [`WALKTHROUGH.md`](Docs/WALKTHROUGH.md) | What happens from process start to JSON, and why each piece looks like that |
| [`LEARNING-PATH.md`](Docs/LEARNING-PATH.md) | What this project teaches, and what it deliberately does not |
| [`API-PLAYBOOK.md`](Docs/API-PLAYBOOK.md) | Every endpoint exercised by hand, with real captured output |
| [`API-DESIGN.md`](Docs/API-DESIGN.md) | What the API should contain, and the decisions behind it |
| [`WORKFLOW.md`](Docs/WORKFLOW.md) | How a change gets made here, from issue to merge |

The rest are reference, best reached from those five. `POSTGRES.md`, `FLUENT.md`, `MIGRATIONS.md`
and `TOOLCHAIN.md` cover the stack. `TESTING.md`, `API-COVERAGE.md`, `ISSUES.md` and `CI.md` cover
the checks. `MIDDLEWARE.md` holds what is planned, and `ISSUE-LOG.md` holds what is already
finished, naming the document that absorbed each lesson.

Outstanding work lives in GitHub Issues, not in `Docs/`. Read the document for *why*, the issue for
*whether it is done*.

## What is deliberately incomplete

Each of these has an issue and a reproduction, so none of them is an oversight:

- **Malformed input returns `500` instead of `400`** on every endpoint, and the body leaks internal
  detail in a non-release build ([#2](https://github.com/sequeiralabs/company-directory/issues/2)).
- **There is no authentication.** Every request succeeds without a credential, and the spec no
  longer claims otherwise ([#24](https://github.com/sequeiralabs/company-directory/issues/24)).
- **Empty names are accepted.** `""` is a valid department or employee name, because nothing in the
  spec or the handlers imposes a minimum length
  ([#12](https://github.com/sequeiralabs/company-directory/issues/12)).
- **A database outage answers `500`, not `503`.** Nothing yet separates "this server is broken"
  from "a dependency is unreachable"
  ([#58](https://github.com/sequeiralabs/company-directory/issues/58)).

[`API-PLAYBOOK.md`](Docs/API-PLAYBOOK.md) → *Where it answers wrongly* reproduces each one, so you
can check a surprising response against a known defect before debugging it.
