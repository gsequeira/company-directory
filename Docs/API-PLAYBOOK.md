# Exercising the API by hand

A run through every operation the server exposes, what it should answer, and the three places it
currently answers something wrong.

**Recorded 2026-08-16**, against `main` with Phase 1 complete. **Every response below is real
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

### Employees

| Operation | Status | Meaning |
| --- | --- | --- |
| `GET /api/employees` | `200` | The list, possibly empty |
| `POST /api/employees` | `201` | Created; body carries the assigned `id` |
| | `409` | An employee already has that first and last name |
| `GET /api/employees/{id}` | `200` | The employee |
| | `404` | No employee with that id; empty body |
| `PATCH /api/employees/{id}` | `200` | Updated, or unchanged if the patch was empty |
| | `404` | No employee with that id |
| | `409` | The resulting first and last name are already taken |
| `DELETE /api/employees/{id}` | `204` | Deleted; no body |
| | `404` | No employee with that id |

### Outside the specification

| Operation | Status | Note |
| --- | --- | --- |
| `GET /health` | `200` | Registered outside the OpenAPI transport, so no `/api` prefix |
| Any operation, malformed input | `500` | Undeclared and incorrect; should be `400` (#2) |

Twenty declared statuses across ten operations, and every one of them has an automated test as well
— see [`API-COVERAGE.md`](API-COVERAGE.md).

## Start it

```bash
docker compose up -d --wait db     # the development database, not db-test
swift run foobar serve             # http://127.0.0.1:8080
```

`autoMigrate()` runs at startup, so the schema is created or brought up to date before the first
request. To start from nothing:

```bash
docker compose exec -T db psql -U foobar -d foobar \
  -c "TRUNCATE employees, departments RESTART IDENTITY CASCADE;"
```

`RESTART IDENTITY` is what makes the ids below reproducible; `CASCADE` is needed because
`employees.department_id` references `departments`.

`/health` is registered outside the OpenAPI transport and therefore has no `/api` prefix:

```console
$ http GET :8080/health
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

### Read

```console
$ http GET :8080/api/departments/1
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
$ http PATCH :8080/api/departments/2 name="Sales and Marketing"
{ "id" : 2, "name" : "Sales and Marketing" }
```

Renaming to the name already held returns `200` rather than conflicting with itself:

```console
$ http PATCH :8080/api/departments/2 name="Sales and Marketing"
HTTP/1.1 200 OK
```

Renaming onto a name another department holds returns `409`:

```console
$ http PATCH :8080/api/departments/2 name=Engineering
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

The same five operations, plus one difference worth seeing.

```console
$ http POST :8080/api/employees firstName=Ada lastName=Lovelace
{ "firstName" : "Ada", "id" : 1, "lastName" : "Lovelace" }

$ http POST :8080/api/employees firstName=Ada lastName=Lovelace
{ "error" : true, "reason" : "An employee named 'Ada Lovelace' already exists" }
```

Uniqueness applies to the pair, enforced by `Migrations.AddEmployeeNameUniqueness`: two employees
may share a first name but not both names. This is a deliberate modelling limitation; see §1.2 and
#25.

Patching one field leaves the other unchanged:

```console
$ http PATCH :8080/api/employees/1 firstName=Augusta
{ "firstName" : "Augusta", "id" : 1, "lastName" : "Lovelace" }
```

The conflict check uses the resulting pair rather than the supplied fields:

```console
$ http PATCH :8080/api/employees/2 firstName=Augusta lastName=Lovelace
{ "error" : true, "reason" : "An employee named 'Augusta Lovelace' already exists" }
```

Sending only `firstName=Augusta` to employee 2 collides identically: the check combines the
supplied field with the stored one before querying.

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

`departmentId` does not appear in any response. The column exists in the database with an enforced
foreign key (#18, step 1), but no operation reads or writes it yet.

## Running it as a script

`Scripts/smoke.sh` walks the same round trip automatically:

```console
$ Scripts/smoke.sh
smoke: http://127.0.0.1:8080
smoke: log /var/folders/.../foobar-smoke-20260816-134547.log
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
$ http POST :8080/api/departments name=
HTTP/1.1 201 Created

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

## Cleaning up

```bash
# stop the server with Ctrl-C, then
docker compose down          # or leave the database running; it costs nothing idle
```

The suite uses `db-test`, a **separate** database on the same server, and reverts every migration
after each test — so running the suite never disturbs whatever you have set up here.
