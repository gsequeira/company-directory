# Exercising the API by hand

A run through every operation the server exposes, what it should answer, and the four places it
currently answers something wrong.

**Recorded 2026-08-16**, against `main` with Phase 1 complete. **Every response below is real
output**, captured from a running server rather than written from the spec — the same standard as
[`POSTGRES.md`](POSTGRES.md). If a response here disagrees with the one you get, the document is
stale and the server is right.

Companion documents: [`API-DESIGN.md`](API-DESIGN.md) is what the API *should* contain,
[`API-COVERAGE.md`](API-COVERAGE.md) is what the automated suite covers, and
[`CI.md`](CI.md) is the equivalent playbook for the build.

`http` is [HTTPie](https://httpie.io). Every command assumes `:8080/api` as the base.

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

**Check it is alive.** `/health` is registered outside the OpenAPI transport, which is why it has no
`/api` prefix:

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

`201` with a body, because the client needs the server-assigned `id`.

```console
$ http POST :8080/api/departments name=Engineering
HTTP/1.1 409 Conflict

{ "error" : true, "reason" : "A department with the name 'Engineering' already exists" }
```

Worth knowing: that `409` can come from either the pre-check in the handler *or* the unique index
catching a lost race, and **nothing from outside can tell which** — see #17.

### Read

```console
$ http GET :8080/api/departments/1
{ "id" : 1, "name" : "Engineering" }

$ http GET :8080/api/departments/999
HTTP/1.1 404 Not Found
content-length: 0
```

**The empty body is the point.** A routing 404 — a path that matches nothing — carries Vapor's
`{"error":true,"reason":"Not Found"}`. An empty body proves the request reached the handler and the
row was absent. The test suite asserts on exactly this.

### Update, including the three cases worth checking

```console
$ http PATCH :8080/api/departments/2 name="Sales and Marketing"
{ "id" : 2, "name" : "Sales and Marketing" }
```

**Renaming to the name it already has must not conflict with itself:**

```console
$ http PATCH :8080/api/departments/2 name="Sales and Marketing"
HTTP/1.1 200 OK
```

**Renaming onto a name another department holds must:**

```console
$ http PATCH :8080/api/departments/2 name=Engineering
{ "error" : true, "reason" : "A department with the name 'Engineering' already exists" }
```

**An empty patch changes nothing and returns `200`:**

```console
$ echo '{}' | http PATCH :8080/api/departments/2 Content-Type:application/json
HTTP/1.1 200 OK

{ "id" : 2, "name" : "Sales and Marketing" }
```

That is the decision in [`API-DESIGN.md`](API-DESIGN.md) §1.3 — `PATCH` is a partial update, so a
body with no fields is a coherent request meaning "change nothing".

**Note `echo '{}' |` rather than `--ignore-stdin`.** HTTPie's `--ignore-stdin` discards a piped
body, so the request goes out with none at all — which is a *different* case and answers `500`. That
mistake is easy to make and looks like a bug in the server.

### Delete

```console
$ http DELETE :8080/api/departments/2
HTTP/1.1 204 No Content

$ http GET :8080/api/departments/2
HTTP/1.1 404 Not Found
```

`204` with no body: there is nothing meaningful to return. Read it back rather than trusting the
status.

## Employees

The same five operations, plus one difference worth seeing.

```console
$ http POST :8080/api/employees firstName=Ada lastName=Lovelace
{ "firstName" : "Ada", "id" : 1, "lastName" : "Lovelace" }

$ http POST :8080/api/employees firstName=Ada lastName=Lovelace
{ "error" : true, "reason" : "An employee named 'Ada Lovelace' already exists" }
```

Uniqueness is on the **pair**, backed by `Migrations.AddEmployeeNameUniqueness`. Two people may
share a first name; they may not share both. That is a deliberate modelling limitation — see
§1.2 and #25.

**Patching one field leaves the other alone:**

```console
$ http PATCH :8080/api/employees/1 firstName=Augusta
{ "firstName" : "Augusta", "id" : 1, "lastName" : "Lovelace" }
```

**And the conflict check uses the resulting pair, not the supplied fields:**

```console
$ http PATCH :8080/api/employees/2 firstName=Augusta lastName=Lovelace
{ "error" : true, "reason" : "An employee named 'Augusta Lovelace' already exists" }
```

Sending only `firstName=Augusta` to employee 2 would collide just the same, because the check
combines it with the stored last name. That is the subtle half of partial update.

```console
$ http DELETE :8080/api/employees/2
HTTP/1.1 204 No Content
```

**No `departmentId` appears anywhere.** The column exists in the database with a live foreign key
(#18 step 1), but nothing in the API reads or writes it yet.

## Where it answers wrongly

A playbook that only shows the happy path is marketing. These are real, reproducible, and each has
an issue.

### Malformed input returns `500` (#2)

Every one of these should be `400`:

```console
$ http GET :8080/api/departments/abc                                    → 500
$ http GET :8080/api/departments/3000000000                             → 500   # > Int32.max
$ echo '{}'            | http POST :8080/api/departments Content-Type:application/json → 500
$ echo '{"name":123}'  | http POST :8080/api/departments Content-Type:application/json → 500
$ printf '{"name":'    | http POST :8080/api/departments Content-Type:application/json → 500
```

**And the body leaks internals.** 671 bytes of decoder detail:

```json
{"error":true,"reason":"Server error - cause description: 'An error occurred while attempting
to parse the request: DecodingError: typeMismatch Int32 - at : Failed to convert to the
requested type. (underlying error: <nil>).', ...
```

That is `ErrorMiddleware` in a non-release build — see [`MIDDLEWARE.md`](MIDDLEWARE.md) →
*Planned — error mapping* for the four lines of Vapor responsible. In a release build the reason
becomes `"Something went wrong."`, so the status is the defect that survives either way.

The `> Int32.max` case is worth its own note: it used to **crash the process**. Declaring
`format: int32` in the spec moved the failure into parsing, so it now returns the wrong status
instead of taking the server down. #15 exists to keep it that way.

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

### There is no authentication

Every request above succeeded without a credential, because none exists. The spec declares `401` on
two of the ten operations and can produce it on none of them — asymmetric as well as unimplemented,
which is why #11 deletes both declarations rather than spreading them. #24 is the feature itself,
and [`MIDDLEWARE.md`](MIDDLEWARE.md) is how it gets wired.

There is nothing to test here. It is listed so the absence is deliberate rather than an oversight.

## Cleaning up

```bash
# stop the server with Ctrl-C, then
docker compose down          # or leave the database running; it costs nothing idle
```

The suite uses `db-test`, a **separate** database on the same server, and reverts every migration
after each test — so running the suite never disturbs whatever you have set up here.
