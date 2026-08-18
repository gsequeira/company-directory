# Exercising the API by hand

A run through every operation the server exposes, what it should answer, and the three places it
currently answers something wrong.

**Recorded 2026-08-16**, against `main` with Phase 1 complete. **Rewritten 2026-08-17 for #18**,
which gives every employee a department and adds the `422` and `409` cases below.
`Scripts/playbook-replay.sh` replays this file against a running server and checks every status —
**32 commands, all passing** — which is how the employee section's staleness was found the moment
the relationship landed, rather than by reading. **Every response below is real
output**, captured from a running server rather than written from the spec — the same standard as
[`POSTGRES.md`](POSTGRES.md). If a response here disagrees with the one you get, the document is
stale and the server is right.

Companion documents: [`API-DESIGN.md`](API-DESIGN.md) is what the API *should* contain,
[`API-COVERAGE.md`](API-COVERAGE.md) is what the automated suite covers, and
[`CI.md`](CI.md) is the equivalent playbook for the build.

`http` is [HTTPie](https://httpie.io). Every command assumes `:8080/api` as the base.

## What there is to exercise

Every status the spec declares, by entity. All of them are demonstrated below.

### Departments

| Operation | Status | Meaning |
| --- | --- | --- |
| `GET /api/departments` | `200` | The list, possibly empty |
| `POST /api/departments` | `201` | Created; body carries the assigned `id` |
| | `409` | A department already holds that name |
| `GET /api/departments/{id}` | `200` | The department |
| | `404` | No department with that id; empty body |
| `PATCH /api/departments/{id}` | `200` | Updated, or unchanged if the patch was empty |
| | `404` | No department with that id |
| | `409` | Another department already holds that name |
| `DELETE /api/departments/{id}` | `204` | Deleted; no body |
| | `404` | No department with that id |
| | `409` | Employees are still assigned to it; the reason says how many |

### Employees

| Operation | Status | Meaning |
| --- | --- | --- |
| `GET /api/employees` | `200` | The list, possibly empty |
| `POST /api/employees` | `201` | Created; body carries the assigned `id` |
| | `409` | An employee already has that first and last name |
| | `422` | The `departmentId` names no department |
| `GET /api/employees/{id}` | `200` | The employee |
| | `404` | No employee with that id; empty body |
| `PATCH /api/employees/{id}` | `200` | Updated, or unchanged if the patch was empty |
| | `404` | No employee with that id |
| | `409` | The resulting first and last name are already taken |
| | `422` | The `departmentId` names no department |
| `DELETE /api/employees/{id}` | `204` | Deleted; no body |
| | `404` | No employee with that id |

### Outside the specification

| Operation | Status | Note |
| --- | --- | --- |
| `GET /health` | `200` | Registered outside the OpenAPI transport, so no `/api` prefix |
| Any operation, malformed input | `500` | Undeclared and incorrect; should be `400` (#2) |

Twenty-three declared statuses across ten operations, and every one of them has an automated test
as well — see [`API-COVERAGE.md`](API-COVERAGE.md).

## Start it

```bash
docker compose up -d --wait db     # the development database, not db-test
swift run company-directory serve             # http://127.0.0.1:8080
```

`autoMigrate()` runs at startup, so the schema is created or brought up to date before the first
request. To start from nothing:

```bash
docker compose exec -T db psql -U company_directory -d company_directory \
  -c "TRUNCATE employees, departments RESTART IDENTITY CASCADE;"
```

`RESTART IDENTITY` is what makes the ids below reproducible; `CASCADE` is needed because
`employees.department_id` references `departments`.

`/health` is registered outside the OpenAPI transport and therefore has no `/api` prefix:

```console
$ http GET :8080/health                                                → 200
{"environment":"development","uptime":1,"timestamp":"2026-08-16T10:10:55Z","checks":{},"status":"ok"}
```

## Departments

### Create, and the conflict

```console
$ http POST :8080/api/departments name=Engineering
HTTP/1.1 201 Created

{ "id" : 1, "name" : "Engineering" }
```

`201` carries a body because the client needs the server-assigned `id`.

```console
$ http POST :8080/api/departments name=Engineering
HTTP/1.1 409 Conflict

{ "error" : true, "reason" : "A department with the name 'Engineering' already exists" }
```

This `409` may originate either from the pre-check in the handler or from the unique index
rejecting a write that lost a race. The two are indistinguishable from outside; see #17.

The rejected request created nothing, so a second department has to be created explicitly. The
update and delete cases below act on it, leaving `Engineering` in place as the name to collide with:

```console
$ http POST :8080/api/departments name=Sales
HTTP/1.1 201 Created

{ "id" : 2, "name" : "Sales" }
```

### Read

```console
$ http GET :8080/api/departments/1                                     → 200
{ "id" : 1, "name" : "Engineering" }

$ http GET :8080/api/departments/999
HTTP/1.1 404 Not Found
content-length: 0
```

The empty body distinguishes this from a routing 404, which carries Vapor's
`{"error":true,"reason":"Not Found"}`. An empty body therefore indicates the request reached the
handler and no row matched. The test suite asserts on this difference.

### Update, including the three cases worth checking

```console
$ http PATCH :8080/api/departments/2 name="Sales and Marketing"        → 200
{ "id" : 2, "name" : "Sales and Marketing" }
```

Renaming to the name already held returns `200` rather than conflicting with itself:

```console
$ http PATCH :8080/api/departments/2 name="Sales and Marketing"
HTTP/1.1 200 OK
```

Renaming onto a name another department holds returns `409`:

```console
$ http PATCH :8080/api/departments/2 name=Engineering                  → 409
{ "error" : true, "reason" : "A department with the name 'Engineering' already exists" }
```

An empty patch changes nothing and returns `200`:

```console
$ echo '{}' | http PATCH :8080/api/departments/2 Content-Type:application/json
HTTP/1.1 200 OK

{ "id" : 2, "name" : "Sales and Marketing" }
```

That is the decision in [`API-DESIGN.md`](API-DESIGN.md) §1.3 — `PATCH` is a partial update, so a
body with no fields is a coherent request meaning "change nothing".

Use `echo '{}' |` rather than `--ignore-stdin`. HTTPie's `--ignore-stdin` discards a piped body, so
the request is sent with no body at all. That is a different case and returns `500`.

### Delete

```console
$ http DELETE :8080/api/departments/2
HTTP/1.1 204 No Content

$ http GET :8080/api/departments/2
HTTP/1.1 404 Not Found
```

`204` carries no body. Confirm the deletion by reading the resource back rather than relying on the
status alone.

## Employees

The same five operations, plus the department relationship added by #18.

Every employee belongs to a department, and the department has to exist first. Only `Engineering`
(id 1) survives the department section above — `Sales` was deleted — so that is what these
reference.

```console
$ http POST :8080/api/employees departmentId:=1 firstName=Ada lastName=Lovelace   → 201
{ "departmentId" : 1, "firstName" : "Ada", "id" : 1, "lastName" : "Lovelace" }

$ http POST :8080/api/employees departmentId:=1 firstName=Ada lastName=Lovelace   → 409
{ "error" : true, "reason" : "An employee named 'Ada Lovelace' already exists" }
```

**`departmentId:=1`, not `departmentId=1`.** HTTPie sends `key=value` as a JSON *string*, and the
field is an integer. Sending `"1"` fails decoding before the handler is reached and returns `500`
— the same defect as any other malformed input (#2), and easy to misread as a bug in this feature.
`:=` sends a raw JSON value.

Uniqueness applies to the pair, enforced by `Migrations.AddEmployeeNameUniqueness`: two employees
may share a first name but not both names. This is a deliberate modelling limitation; see §1.2 and
#25.

As with departments, the rejected request created nothing, so employee 2 has to be created
explicitly. It shares the last name, which is what lets the patch cases below collide:

```console
$ http POST :8080/api/employees departmentId:=1 firstName=Byron lastName=Lovelace → 201
{ "departmentId" : 1, "firstName" : "Byron", "id" : 2, "lastName" : "Lovelace" }
```

A `departmentId` naming no department is refused, and nothing is created:

```console
$ http POST :8080/api/employees departmentId:=999 firstName=Nobody lastName=Nowhere → 422
{ "error" : true, "reason" : "No department exists with id 999" }
```

`422` rather than `404` because the resource being addressed — the employees collection — exists.
What is missing is named in the payload. It also keeps the single-employee `404` below unambiguous,
which one status serving both meanings would not.

Patching one field leaves the others unchanged, the department included:

```console
$ http PATCH :8080/api/employees/1 firstName=Augusta                   → 200
{ "departmentId" : 1, "firstName" : "Augusta", "id" : 1, "lastName" : "Lovelace" }
```

The conflict check uses the resulting pair rather than the supplied fields:

```console
$ http PATCH :8080/api/employees/2 firstName=Augusta lastName=Lovelace → 409
{ "error" : true, "reason" : "An employee named 'Augusta Lovelace' already exists" }
```

Sending only `firstName=Augusta` collides identically, because the check combines the supplied
field with the stored one before querying. Employee 2's stored last name is already `Lovelace`:

```console
$ http PATCH :8080/api/employees/2 firstName=Augusta                   → 409
{ "error" : true, "reason" : "An employee named 'Augusta Lovelace' already exists" }
```

Supplying `departmentId` moves the employee. An unknown one is refused the same way as on create,
and the employee is left untouched:

```console
$ http PATCH :8080/api/employees/2 departmentId:=999                   → 422
{ "error" : true, "reason" : "No department exists with id 999" }
```

## Deleting a department that still has employees

The one place the two resources visibly constrain each other. Both employees still reference
`Engineering`:

```console
$ http DELETE :8080/api/departments/1                                  → 409
{ "error" : true, "reason" : "Department 'Engineering' still has 2 employees assigned to it" }
```

This is refused twice over, and the redundancy is deliberate. The handler counts the employees
first, which is what produces a message naming the number; the foreign key's `ON DELETE RESTRICT`
refuses the statement regardless, which is what makes the count safe to be stale. Neither is
sufficient alone — a constraint cannot explain itself, and a pre-check cannot be atomic. See
[`API-DESIGN.md`](API-DESIGN.md) §2.4.

Removing the employees first makes the same request succeed, which is the point: the restriction
is on the reference, not on the department.

```console
$ http DELETE :8080/api/employees/2
HTTP/1.1 204 No Content
```

All three single-employee operations return `404` with an empty body for an id that does not exist:

```console
$ http GET    :8080/api/employees/999          → 404, content-length: 0
$ http PATCH  :8080/api/employees/999 firstName=Nobody   → 404, content-length: 0
$ http DELETE :8080/api/employees/999          → 404, content-length: 0
```

`departmentId` is read straight from the stored foreign key, so returning it costs no extra query
and there is no N+1 here. That changes the day a response carries the department's *name* instead
of its id — see [`FLUENT.md`](FLUENT.md) → *The N+1 problem*.

## Running it as a script

`Scripts/smoke.sh` walks the same round trip automatically. It needs a database and a **running
server** — it drives one over a real socket rather than starting anything itself.

```bash
# 1. the development database
docker compose up -d --wait db

# 2. the server, in another terminal (or append & to background it)
swift run company-directory serve

# 3. the checks
Scripts/smoke.sh
```

Stop the server with Ctrl-C when finished. The database can stay up; it costs nothing idle.

```console
$ Scripts/smoke.sh
smoke: http://127.0.0.1:8080
smoke: log /var/folders/.../companydirectory-smoke-20260816-134547.log
  ok    server is reachable and /health answers
  ok    create department
  ok    duplicate department conflicts
  ...
  ok    deleted department is gone

smoke: 19 passed
```

It takes an optional base URL (`Scripts/smoke.sh http://host:port`), writes full request and
response detail to a log file, and exits non-zero if any check fails. On failure it prints the
offending response to stdout as well; on success the log is there and nobody needs to read it.

### What it is for

**Not correctness.** The suite asserts more than this does and owns that question. This script
covers the three things the suite structurally cannot, because it drives the application in-process
and reverts its migrations after each test:

| Gap | Why the suite misses it |
| --- | --- |
| A real server on a real port | `TestHelpers.withApplication` calls `application.sendRequest` in process; nothing binds a socket |
| `/health` | Registered outside the OpenAPI transport, so no generated handler and no test |
| Startup against a populated database | Every test reverts its migrations, so migrations are only ever exercised against an empty schema |

The last is the one that has bitten this project before: a migration that succeeds on an empty
schema and fails against existing rows passes `swift test` and breaks the development server. See
[`MIGRATIONS.md`](MIGRATIONS.md).

### It is safe to run against a database with data

Every name it creates carries a per-run suffix, and it deletes what it created on exit — including
when a check fails part way through. Verified by running it against a populated database and
confirming no `smoke-` rows survive, on both the passing and the failing paths.

### There is a Swift version too, and they are not redundant

`Tests/CompanyDirectoryTests/SmokeTests.swift` walks the same ground as a Swift Testing suite:

```bash
docker compose up -d --wait db                    # the server needs it
swift run company-directory serve &                          # backgrounded so the next line can run
SMOKE_BASE_URL=http://127.0.0.1:8080 swift test --filter SmokeTests
kill %1                                           # stop the server afterwards
```

Note `db`, not `db-test`: this drives a real server, which uses the development database. The suite
proper still uses `db-test`, so the two do not interfere.

It runs **only** when `SMOKE_BASE_URL` is set — an ordinary `swift test` reports it as skipped
rather than failing, so CI is unaffected.

| | `Scripts/smoke.sh` | `SmokeTests.swift` |
| --- | --- | --- |
| Build required | None | The test target |
| Runs from | Any machine with HTTPie | A checkout of this repository |
| Assertions | Status codes, as strings | Responses decoded into `Components.Schemas.*` |
| Catches a spec change | No | **Yes — it stops compiling** |

The last row is the difference worth having. The shell script compares `201` to `201` and cannot
know what the body should contain. The Swift suite decodes into the generated types, so adding a
required field to `Employee` breaks this file at compile time rather than at some later run.

The shell version keeps its place because it needs neither a toolchain nor the repository, which is
what a smoke test against a deployed server actually requires.

### Replaying this document

`Scripts/playbook-replay.sh` runs the commands in this document, in order, and checks each response
against the status recorded here.

```bash
docker compose up -d --wait db
swift run company-directory serve                 # in another terminal
Scripts/playbook-replay.sh                       # -y skips the confirmation
```

It reads the commands out of this file rather than carrying its own copy, so there is no second
sequence to keep in step. Every `$` line in a `console` block is replayed, and its expected status
comes from either the `→ NNN` annotation on the command or the `HTTP/1.1 NNN` line beneath it. A
command with neither is printed under *not replayable, so not checked* rather than silently
dropped, which is what keeps an unannotated addition visible.

**It truncates `employees` and `departments`.** That is the difference from `Scripts/smoke.sh`,
which generates suffixed names and is safe against a populated database. This document records
fixed ids, so reproducing it requires an empty database and restarted sequences. It prompts before
doing so unless given `-y`, and refuses to run unprompted without `-y` when stdin is not a terminal.

It checks statuses, not bodies. The ids and names in the responses above are still read by eye.

The reason it exists is a defect found on 2026-08-17: neither entity section created its second
record, because the duplicate `POST` that demonstrates the `409` creates nothing. Roughly half of
each section addressed an id that did not exist and answered `404`. The captures were real output,
but taken against a database that already held those records, and verifying each response in
isolation cannot detect that the commands do not produce the state they assume. Replaying them in
order from `TRUNCATE` does — removing that one `POST` again now fails five checks.

### When not to wire it into CI

Not as a second job. CI already runs the suite against a service container, so a smoke test there
would double the maintenance for no new signal. It earns a place the day there is a deployment step
to run it after.

## Where it answers wrongly

Three reproducible cases where the response does not match the contract. Each has an open issue.

They are recorded here so that a reader who receives a `500` can tell whether it is a known defect
or a malformed request of their own. Authentication is covered separately below: its absence is not
a defect, since the specification does not ask for it.

### Malformed input returns `500` (#2)

Every one of these should be `400`:

```console
$ http GET :8080/api/departments/abc                                    → 500
$ http GET :8080/api/departments/3000000000                             → 500   # > Int32.max
$ echo '{}'            | http POST :8080/api/departments Content-Type:application/json → 500
$ echo '{"name":123}'  | http POST :8080/api/departments Content-Type:application/json → 500
$ printf '{"name":'    | http POST :8080/api/departments Content-Type:application/json → 500
```

The body also exposes internal detail — 671 bytes of it:

```json
{"error":true,"reason":"Server error - cause description: 'An error occurred while attempting
to parse the request: DecodingError: typeMismatch Int32 - at : Failed to convert to the
requested type. (underlying error: <nil>).', ...
```

This is `ErrorMiddleware` in a non-release build; see [`MIDDLEWARE.md`](MIDDLEWARE.md) →
*Planned — error mapping* for the responsible code. In a release build the reason becomes
`"Something went wrong."`. The incorrect status remains in both builds.

The `> Int32.max` case previously terminated the process. Declaring `format: int32` in the spec
moved the failure into parameter parsing, so it now returns an incorrect status rather than exiting.
#15 covers a regression test for this.

### Empty names are accepted (#12)

```console
$ http POST :8080/api/departments name=                                → 201
{ "id" : 3, "name" : "" }
```

Conformant — the spec sets no `minLength` — and almost certainly not intended. Fix belongs in the
spec, not the handler.

### List order is not guaranteed (#3)

`GET /api/departments` and `GET /api/employees` have no `ORDER BY`. The order you see is whatever
PostgreSQL returns, which is stable enough to be misleading and not stable enough to rely on. Do not
write assertions against position until #3 lands.

## Not wrong, but absent: authentication

Every request above succeeded without a credential, because none exists.

The spec used to declare `401` on two of the ten operations and could produce it on none — a
response no code path could return, and asymmetric besides, since it claimed creating a department
needed authentication while deleting one did not. **#11 deleted both declarations**, so the contract
now describes the server that exists rather than one that does not. #24 is the feature itself, and
[`MIDDLEWARE.md`](MIDDLEWARE.md) is how it gets wired.

There is nothing to exercise. The section exists to record that the absence is intentional and
tracked.

## Clean up

Two processes were started: the server and the database container.

### The server

In the terminal running it, **Ctrl-C**. Vapor traps `SIGINT` and shuts down through
`asyncShutdown()`, closing the database connection pool rather than dropping it.

If it was backgrounded with `&`, `kill %1` from the same shell is *not* enough. `swift run` compiles
and then execs the binary as a **child process**, and the job is the parent. Terminating it leaves
the server running and still holding the port:

```console
$ kill %1
$ lsof -nP -iTCP:8080 -sTCP:LISTEN
COMMAND     PID  USER   FD   TYPE  NAME
CompanyDi 38948 glenn   16u  IPv4  TCP 127.0.0.1:8080 (LISTEN)

$ http GET :8080/health                                                → 200
```

The next `swift run company-directory serve` then fails to bind, and the orphan answers requests as
though nothing happened. Address the listener rather than the job:

```bash
lsof -ti tcp:8080 | xargs kill        # by the port it holds
pkill -f 'company-directory serve'    # or by name — matches the swift run wrapper too
```

Both send `SIGTERM`, which Vapor handles the same way as Ctrl-C. Confirm with
`lsof -ti tcp:8080`, which should print nothing.

### The database

```bash
docker compose stop db     # keeps the data
docker compose down        # removes the containers, keeps the volume
docker compose down -v     # removes the volume as well — every row goes
```

Stopping is rarely worth it; an idle PostgreSQL container costs almost nothing, and leaving it up
means the next session starts at `swift run`. Use `down -v` only to rebuild from nothing, remembering
that `autoMigrate()` recreates the schema at startup but no data comes back.

## Cleaning up

```bash
# stop the server with Ctrl-C, then
docker compose down          # or leave the database running; it costs nothing idle
```

The suite uses `db-test`, a **separate** database on the same server, and reverts every migration
after each test — so running the suite never disturbs whatever you have set up here.
