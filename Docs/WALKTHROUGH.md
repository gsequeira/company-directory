# Walkthrough

A narrative tour of this codebase, following **execution** rather than subject matter: what happens
from process start to JSON on the wire, and why each piece looks the way it does.

**Written:** 2026-08-17, at `deddae1`, with Phase 2 complete — employees now belong to departments.

**Assumed:** you read Swift comfortably — `async`/`await`, protocols, generics, `Codable` — and you
have never used Vapor, Fluent, or the OpenAPI generator. Everything specific to those is explained
where it first appears. Nothing about the language is.

## How to read this, and what it is not

This is the second thing to read, not the first. [`README.md`](../README.md) gets the project
running; this explains what you just started.

It is **connective tissue, and nothing else**. Every subject here has a document that owns it, and
the rule for this file is that depth lives there. Where you see a link, follow it — the sentence
here is a summary and the document behind it is the actual answer. A walkthrough that explained
migrations properly would quietly have become a worse second copy of
[`MIGRATIONS.md`](MIGRATIONS.md), with none of the maintenance.

For the same reason it references source as `` `File.swift:symbol` `` and never pastes function
bodies. Quoted code drifts silently; a symbol name that stops existing can at least be caught by a
grep ([#60](https://github.com/sequeiralabs/company-directory/issues/60)).

## The shape

**Startup**, once, before anything is listening:

```
Entrypoint.swift            @main — builds the Application, runs a ServiceGroup
  └── configureServer                                    ServerService.swift
        ├── configureDatabase   driver, migrations       Database.swift
        ├── routes              /health                  Routes.swift
        └── registerHandlers    the ten API operations   VaporTransport
```

**Then, per request**, for the lifetime of the process:

```
HTTP  →  Vapor router  →  generated decoding  →  APIHandler.swift
                                                      ↓
                                        Models.swift  ·  FluentKit
                                                      ↓
                                        PostgresNIO   ·  Postgres
                                                      ↓
              JSON  ←  generated response  ←  SchemaConversions.swift
```

Ten operations, 1,031 lines of hand-written Swift. Three times as much again is generated at build
time and is not in the repository — see [§2](#2-the-generated-layer).

## 1. Startup

### `Entrypoint.swift` — not the Vapor you may have seen

If you half-know Vapor, this file will mislead you. There is no `app.run()` and no
`configure(app)`. Instead `Entrypoint.swift:main` calls `Application.make(logger:)`, hands the
result to `ServerService.swift:configureServer`, and runs the result inside a `ServiceGroup`.

`ServiceGroup` is **swift-service-lifecycle**, a swift-server package rather than a Vapor one. It
owns process lifetime: a set of services, each with a `run()` that lasts as long as the service
should, plus signal handling. The two signals are configured differently on purpose —
`gracefulShutdownSignals: [.sigint]` drains in-flight requests before exiting, and
`cancellationSignals: [.sigterm]` does not wait. That is the difference between Ctrl-C at your
terminal and a container runtime reclaiming the process.

`Vapor.Application` is the container for everything process-wide: the router, the registered
databases, middleware, the event loop group. It is created once and passed around during
configuration. It is **not** `Sendable`, which matters later.

The `catch` is the fail-fast path: on any configuration error it shuts the application down, logs,
and calls `exit(1)`. A server that cannot reach its database should not bind a port and start
answering — and this is verifiable, since the port is never opened. The success path has a real
gap: `asyncShutdown()` is never called ([#4](https://github.com/sequeiralabs/company-directory/issues/4)).

### `ServerService.swift:configureServer` — the assembly point

Four steps, and the order is the dependency order:

1. `configureDatabase` — register the driver, run migrations.
2. `routes(application)` — the hand-written routes.
3. `APIHandler(database: application.db)` — build the handler.
4. `VaporTransport` + `registerHandlers` — attach the generated routes.

It returns a `Service` that has **not** started. Nothing touches the network until the
`ServiceGroup` runs it, which is what lets the test suite build a fully configured application and
send requests straight into it without ever opening a socket.

`ServerService.swift:ServerService` is a four-line wrapper whose `run()` calls
`application.execute()`. That is the whole adaptation between Vapor's server and ServiceLifecycle's
protocol.

### `Database.swift:configureDatabase` — and the seam that saved the development database

Two jobs: point Fluent at PostgreSQL, and run migrations.

**Fluent** is Vapor's ORM. `application.databases.use(_:as:)` registers a configured driver under an
identifier — here `.psql` — and `application.db` later resolves it. The configuration comes from
`Database.swift:postgresConfiguration`, where `DATABASE_URL` wins if present (the form hosting
platforms inject) and the individual variables are the local path. Their defaults match
`docker-compose.yml`, which is why a fresh clone needs no configuration at all. `tls: .disable` is
correct for a container on this machine and wrong for anything across a network.

Migrations are listed explicitly and **the order is append-only**. Fluent records each applied
migration in a `_fluent_migrations` table and never runs it twice, so editing a migration that has
already run changes nothing anywhere it has already been applied. [`MIGRATIONS.md`](MIGRATIONS.md)
→ *The three rules* is the full account; the three-step sequence that made `department_id`
mandatory is at → *Steps 2 and 3, and the one Fluent cannot express*.

Two things in this function are worth knowing before you read any further.

**The `configuration` parameter is a seam, not a convenience.** Without it, `configureServer` would
overwrite whatever database a test had registered — and because the suite calls `autoRevert()`,
that would have meant the test run dropping the *development* schema while reporting success. Under
the SQLite this project started on, the damage was invisible. Under PostgreSQL it would not have
been. [`POSTGRES.md`](POSTGRES.md) → *6a — First, make the database injectable*.

**The error classification is fragile and known to be.** `autoMigrate()` does not throw a typed
error distinguishing a migration failure from a configuration failure, so the message string is
matched instead. Any upstream rewording silently reclassifies it
([#5](https://github.com/sequeiralabs/company-directory/issues/5)).

`Database.swift:DatabaseSetupError` is named the way it is to avoid a collision: FluentKit declares
a `DatabaseError` protocol, and a same-named type in this module would shadow it in every file.
[`FLUENT.md`](FLUENT.md) → *Why the `FluentKit.` qualifier*.

### `Routes.swift` — the one hand-written route

`Routes.swift:routes` registers exactly one thing, `Health.swift:healthRoute`. In Vapor a route is
a closure on a `RoutesBuilder`; `application.get("health") { ... }` binds `GET /health` and returns
anything conforming to `Content`, which is Vapor's `Codable` plus content-type negotiation.

Two details are load-bearing.

**`/health` has no `/api` prefix** because it is registered directly on the application rather than
through the OpenAPI transport, which mounts everything under the spec's `servers` entry. That is
the visible consequence of the split described in the next section, and the reason the playbook
writes `http GET :8080/health` without `/api`.

**`Health.swift:healthRoute` copies `application.environment.name` into a local before the closure.**
This is Swift 6 language mode doing its job: `Application` is not `Sendable`, the closure is
`@Sendable`, so capturing the application would not compile. Capturing the `String` it needs does.
You will see this shape wherever a Vapor handler needs a scrap of configuration.

The response's `checks` field is `[:]` — empty. `/health` reports that the process is alive and
claims nothing about the database, which is currently honest only by accident, since the field
exists and reads as though checks were run
([#54](https://github.com/sequeiralabs/company-directory/issues/54)).

### `VaporTransport` — where the generated half attaches

`VaporTransport(routesBuilder: application)` adapts Vapor's router to the transport protocol the
generated code expects, and `registerHandlers(on:serverURL:configuration:)` walks every operation
in the spec and binds it. After this call the router holds ten more routes, none of which appear as
a `get`/`post` call anywhere in the source.

## 2. The generated layer

### Where the code actually is

**The generated code is not in the repository.** `Package.swift` attaches `OpenAPIGenerator` as a
build plugin to the executable target, so the types materialise into `.build` during compilation.
Grep for `struct Employee` and you will find only the Fluent model — the API type of the same name
is real, compiled, and nowhere in `git ls-files`.

To read it:

```bash
find .build/plugins/outputs -path '*GeneratedSources*' -name '*.swift'
```

Three files — `Types.swift`, `Server.swift`, `Client.swift` — totalling **3,197 lines against the
1,031 written by hand**. Three quarters of this project is compiled from a YAML file. (The search may
also turn up a stale `foobar/` output directory, left by the rename in #52; the
`company-directory/` one is current.)

Three families of type come out of `Sources/CompanyDirectory/openapi.yaml`:

- **`Components.Schemas.*`** — the request and response bodies. `Components.Schemas.Employee`,
  `Components.Schemas.CreateEmployeeRequest`, `Components.Schemas.ConflictError`,
  `Components.Schemas.ReferenceError`.
- **`Operations.*`** — one namespace per operation, each with an `Input` and an `Output`. The
  `Output` is an enum whose cases are the **declared** responses, which is the whole trick:
  `Operations.CreateEmployee.Output` has a `.created`, a `.conflict` and an `.unprocessableContent`
  case because the spec declares `201`, `409` and `422`.
- **`APIProtocol`** — one requirement per operation.

### `APIProtocol` is the contract, enforced by the compiler

`APIHandler.swift:APIHandler` is a `struct` conforming to `APIProtocol`. That single conformance is
what makes this project spec-first in a way that survives carelessness: add an operation to
`openapi.yaml` and the build breaks until a method exists to serve it. Remove a declared response
and every `return` producing it stops compiling.

Regenerating is just building. There is no command to remember and no generated file to commit,
which also means there is no way for the generated types and the spec to disagree.

**The enum is not quite closed, and the exception is worth knowing.** Every generated `Output` also
carries `case undocumented(statusCode: Swift.Int, OpenAPIRuntime.UndocumentedPayload)`. It exists
mainly for the client half of the generator — a client has to represent a response the spec never
declared — but it is the same type the server returns, so a handler *can* reach for it. Nothing in
this codebase does.

What the contract actually guarantees, then, is narrower than "undeclared statuses are impossible":
**you cannot return one by accident.** Every status a handler produces on purpose is a case the
spec put there, and stepping outside means naming `.undocumented` explicitly in a diff someone will
read. That is a weaker property than it first appears and still the one that matters.

It also explains the shape of the failures in [§6](#6-http-statuses-including-the-wrong-ones). The
`500`s are not handler returns at all — they are thrown errors escaping past the handler into the
error middleware, which is the one route to a response the spec knows nothing about that involves
no deliberate act. And a response shape the spec *cannot* express forced a design change outright
during Phase 2.

## 3. One request, end to end

`POST /api/employees` is the richest path in the codebase, so it is the one worth tracing. It
decodes a generated request type, runs two pre-checks, writes through a foreign key, and can leave
four different ways.

```console
$ http POST :8080/api/employees departmentId:=1 firstName=Ada lastName=Lovelace
```

**Decoding happens before the handler runs.** The generated code parses the body into
`Components.Schemas.CreateEmployeeRequest` before `createEmployee` is entered. This is why a
malformed body cannot be handled inside the handler, and why fixing
[#2](https://github.com/sequeiralabs/company-directory/issues/2) means middleware rather than a
`catch` ([`MIDDLEWARE.md`](MIDDLEWARE.md) → *Planned — error mapping*).

It is also the first thing a newcomer trips over. In HTTPie, `departmentId=1` sends the **string**
`"1"` and `departmentId:=1` sends the number. The first produces a `500`, which is #2 wearing a
disguise.

Inside `APIHandler.swift:createEmployee`, in order:

1. **Duplicate-name pre-check.** A query on first and last name; a match returns `409` with
   `Components.Schemas.ConflictError`.
2. **Department existence check.** `Models.Department.find(...)`; absent returns `422` with
   `Components.Schemas.ReferenceError` naming the missing id. Without this, the foreign key would
   still refuse the insert — but with an opaque constraint failure instead of a response that says
   which department is missing.
3. **Save.** `newEmployee.save(on: database)`.

Both pre-checks are **read-then-write and therefore racy**, and both are deliberate. The `catch`
clauses after the save are the other half:

```
catch … == .unique      → 409   the name was taken between the check and the insert
catch … == .foreignKey  → 422   the department was deleted between the check and the insert
```

This is the pattern the whole codebase uses, and the reasoning generalises: **the pre-check
produces a good message, the constraint produces atomicity, and neither is sufficient alone.** The
same pair appears in `APIHandler.swift:deleteDepartment`, where the count of remaining employees
makes the `409` useful and `onDelete: .restrict` makes it safe for that count to be stale
([`API-DESIGN.md`](API-DESIGN.md) → *2.4* → *Enforced twice, deliberately*).

Distinguishing those two `catch` clauses is what
[#21](https://github.com/sequeiralabs/company-directory/issues/21) bought. Before it, both matched
`isConstraintFailure`, so a foreign-key violation was reported as a duplicate name that did not
exist. `ConstraintViolation.swift` reads the PostgreSQL SQLSTATE — `23505` unique, `23503`/`23001`
foreign key — and **is the only file in the target that imports PostgresNIO.** Every handler stays
driver-agnostic; one file knows what a SQLSTATE is.

## 4. The model layer

`Models.swift` is a caseless `enum` used as a namespace, so the Fluent `Employee` and the generated
`Employee` can coexist unambiguously as `Models.Employee` and `Components.Schemas.Employee`.

Fluent models are **final classes** using property wrappers to declare columns: `@ID`, `@Field`,
`@Timestamp`, and for relationships `@Parent` and `@Children`. Each wrapper's projected value —
reached with `$` — is the queryable form, which is why filters read
`.filter(\.$name == someName)` while plain reads use `model.name`.

They are `@unchecked Sendable`, which is the standard Fluent idiom rather than a shortcut taken
here: models are mutated during hydration and cannot satisfy the compiler's checking. It is sound
in this codebase because instances never outlive the request that created them — every handler
converts to a value type before returning.

**The relationship is one column and one query.** `Models.Employee` owns `@Parent(key:
"department_id")`; `Models.Department` declares `@Children(for: \.$department)`, which has no column
and needs no migration — it is a query waiting to be run.

The distinction that governs query cost:

| Expression | Cost | Available |
| --- | --- | --- |
| `employee.$department.id` | free — it *is* a column on the fetched row | always |
| `employee.department` | a query per employee | only after `.with(\.$department)`; **traps** otherwise |

`SchemaConversions.swift` uses the first. Responses carry `departmentId` and never the department's
name, so nothing needs eager loading and there is no N+1 here yet. The day a response carries the
name, there is — [`FLUENT.md`](FLUENT.md) → *The N+1 problem, which Phase 2 walks straight into*
describes what changes, and why counting queries beats judging by feel at these row counts.

That trap is a deliberate design choice by Fluent, and a good one: an unloaded relation and an
empty one are never confused.

## 5. Back out — building the response

`SchemaConversions.swift` converts models to generated response types, and **the direction of the
dependency is the point**. The conversions are initialisers on the *schema* types, not `toSchema()`
methods on the models, so the API layer knows about the domain model and never the reverse.
Regenerating the spec cannot ripple into `Models.swift`.

Each one `throws`, because a Fluent model's `id` is optional until the database assigns it. They
call `requireID()`. The previous version used `model.id!`, and the difference is not stylistic: a
force unwrap **traps**, and a trap in a server takes down the process and every in-flight request
with it, not just the one that hit the bad model. Now it surfaces as a `500` through Vapor's error
middleware. [`FLUENT.md`](FLUENT.md) → *Why `model.id` is optional, and what to do about it*.

This project registers **no middleware of its own**. Vapor installs two by default, and the second
is the one that matters here: `ErrorMiddleware.default(environment:)` catches anything thrown out
of a handler and turns it into a response — a type conforming to `AbortError` keeps its status, and
**everything else becomes a `500`**. That single rule explains most of the wrong statuses in the
next section. [`MIDDLEWARE.md`](MIDDLEWARE.md) → *What is registered today*.

## 6. HTTP statuses, including the wrong ones

| Choice | Why |
| --- | --- |
| `201` + body on create | The client needs the server-assigned `id` |
| `204` + no body on delete | Nothing meaningful to return |
| `404` with an **empty** body | Distinguishes a handler `404` from a router `404`, which carries Vapor's `{"error":true,"reason":"Not Found"}` — and it is what the tests assert on |
| `409` for uniqueness | Returned from two places, pre-check and constraint `catch`, which no test can currently distinguish ([#17](https://github.com/sequeiralabs/company-directory/issues/17)) |
| `409` from `deleteDepartment` | The department still has employees; the reason says how many ([`API-DESIGN.md`](API-DESIGN.md) → *2.4*) |
| `422` for an unknown `departmentId` | The body is well-formed and the reference is not — and see below, because this is not what was planned |
| `200` for an empty `PATCH` | A client diffing to build a patch legitimately produces `{}` ([`API-DESIGN.md`](API-DESIGN.md) → *1.3*) |
| `500` for malformed input | **Wrong.** Undeclared, and it breaks the contract on all ten operations ([#2](https://github.com/sequeiralabs/company-directory/issues/2)) |
| `500` while the database is down | **Wrong.** A dependency being unreachable is a `503` ([#58](https://github.com/sequeiralabs/company-directory/issues/58)) |

The last two rows are why this section exists. A walkthrough that only describes what the code gets
right is marketing.

**The `422` is worth the detour**, because it is a case of the tooling refusing a design rather than
implementing it. The plan in [`API-DESIGN.md`](API-DESIGN.md) → *2.1* was a `404` naming the missing
department. But `updateEmployee` already returns `404` with an **empty** body for an unknown
employee, and OpenAPI cannot declare a response whose body is sometimes present and sometimes
absent. One operation, one status, one body shape. So the reference failure took `422 Unprocessable
Content` with its own `ReferenceError` schema, which is arguably the better answer anyway — the
employee id in the path is a routing concern and the department id in the body is a content
concern — but it was chosen under constraint, not from first principles.

## 7. The seams, and why each is where it is

Collected, because the reasons are scattered across the tour and the pattern is worth seeing whole.

| Seam | What it prevents |
| --- | --- |
| `configureDatabase` takes an injectable configuration | A test run dropping the development schema while reporting success |
| Conversions live on the schema type | Regenerating the spec rippling into `Models.swift` |
| `ConstraintViolation` is the only PostgresNIO import | Ten handlers knowing what a SQLSTATE is |
| `DatabaseSetupError` is not called `DatabaseError` | Shadowing FluentKit's protocol module-wide |
| `configureServer` returns an unstarted `Service` | Tests needing a real socket |
| `/health` is registered outside the transport | Exemption logic when authentication arrives — grouping the transport protects the API and leaves probes reachable ([`MIDDLEWARE.md`](MIDDLEWARE.md) → *The two registration points*) |
| Handlers return `$department.id`, never `department` | An N+1 nobody notices at ten rows |

## 8. What is not here yet

Phases 3 and 4 — a transfer operation and employment status — are specified in
[`LEARNING-PATH.md`](LEARNING-PATH.md) → *Phase 3* and *Phase 4*, and have no issues open yet.
Neither would invalidate a section above; both would add one. They are also the two phases that
stop this from being a CRUD project: the transfer is the first operation that *needs* a
transaction, and status is the first field that is a state machine rather than a value.

The gaps that would change what you read here are tracked rather than hidden:

- **No authentication.** Every request succeeds without a credential, and the spec no longer claims
  otherwise ([#24](https://github.com/sequeiralabs/company-directory/issues/24)).
- **No transactions anywhere.** The read-then-write pattern in
  [§3](#3-one-request-end-to-end) is backed by constraints rather than by isolation. That is
  adequate here and would not be in a system where a single request writes more than one row —
  [`LEARNING-PATH.md`](LEARNING-PATH.md) → *Transactions and consistency*.
- **No tracing.** Vapor's `TracingMiddleware` and FluentKit's per-query spans are both already in
  the dependency graph and both inert, because nothing calls
  `InstrumentationSystem.bootstrap` ([#45](https://github.com/sequeiralabs/company-directory/issues/45)).
- **List endpoints return rows in no guaranteed order**
  ([#3](https://github.com/sequeiralabs/company-directory/issues/3)), and there is no pagination
  ([#22](https://github.com/sequeiralabs/company-directory/issues/22)).

For the behaviour of every endpoint as actually captured, rather than as described here, see
[`API-PLAYBOOK.md`](API-PLAYBOOK.md) — it is replayed against a running server by
`Scripts/playbook-replay.sh`, so its statuses are checked rather than asserted.
