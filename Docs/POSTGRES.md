# Moving from SQLite to PostgreSQL

A step-by-step migration from the in-memory SQLite database to PostgreSQL running in Docker, with
a verification checkpoint after every step.


> **Renamed 2026-08-16.** This project was called `foobar` until the module became
> `CompanyDirectory`. Captured output below still shows the old name — for example
> `foobar.Migrations.CreateDepartments` — because it is a record of what actually ran. The
> database, its user and its volume were renamed to `company_directory` in the same change.
> Underscores rather than hyphens, because a hyphenated PostgreSQL identifier must be quoted in
> every statement that names it. See #52.

**Status as of 2026-08-14: steps 0–7 complete.** The application and the test suite both run on
PostgreSQL, 14/14 tests pass in about 1.5 seconds, and the outputs recorded below are real rather
than expected. This was step 3 of the sequence in [`LEARNING-PATH.md`](LEARNING-PATH.md), pulled
forward ahead of CI because a CI workflow written against SQLite would have been rewritten a week
later.

Companion documents: [`LEARNING-PATH.md`](LEARNING-PATH.md) explains *why* this move is worth
making early, [`API-DESIGN.md`](API-DESIGN.md) §2.3 is the foreign-key problem that motivates it,
[`TOOLCHAIN.md`](TOOLCHAIN.md) covers which Swift compiles all this,
[`MIGRATIONS.md`](MIGRATIONS.md) covers schema changes made *after* this move, and
[`TESTING.md`](TESTING.md) holds the assertion conventions the new test harness must keep
satisfying.

## Why this is step 3 and not step 8

Phase 2 declares a foreign key from `employees` to `departments`. SQLite will very likely record it
in the schema and **not enforce it**, because foreign keys require `PRAGMA foreign_keys = ON` per
connection and it is off by default. You would write `.references("departments", "id")`, believe you
have referential integrity, and not have it.

Doing this before Phase 2 means the constraint is real the first time it exists. Doing it after
means writing Phase 2 twice.

## What actually changes

| File | Change | Risk |
| --- | --- | --- |
| `docker-compose.yml` | New. Two Postgres services. | None — new file |
| `Package.swift` | `fluent-sqlite-driver` → `fluent-postgres-driver` | Low |
| `Sources/CompanyDirectory/Database.swift` | Driver swap, connection read from the environment, injectable configuration | Low |
| `Sources/CompanyDirectory/ServerService.swift` | Passes a database configuration through to `configureDatabase` | Low, but **do not skip** — see step 6a |
| `Tests/CompanyDirectoryTests/TestHelpers.swift` | Loses free per-test isolation | **This is the real work** |
| `Tests/CompanyDirectoryTests/APIHandlerTests.swift` | `.serialized` trait, unused import removed | Low |
| `.gitignore` | Ignore `.env` | None |

`Sources/CompanyDirectory/APIHandler.swift`, `Models.swift` and `Migrations.swift` need **no changes**. Worth
knowing why, because it is not luck:

- The handler never inspects database error text. Both duplicate checks (`APIHandler.swift:37` and
  `:165`) are pre-checks that query for an existing row; the unique-constraint violation path just
  propagates the error. SQLite and Postgres word that error completely differently, and it would
  have been a porting bug if the handler had matched on it.
- The models use `@ID(custom: "id", generatedBy: .database)` and Fluent's portable `DatabaseSchema`
  types (`.int32`, `.string`, `.datetime`), not raw SQL.

---

# Step 0 — Confirm the starting point

Everything below assumes a clean tree on `main` with the suite green, so that any breakage during
the migration is unambiguously caused by the migration.

```bash
git status --short          # expect: no output
swift build 2>&1 | tail -5  # expect: no warnings
swift test 2>&1 | tail -5   # expect: every test passing
docker context ls           # expect: one context marked *, and no ERROR column entry
docker compose version      # expect: v2 or later
```

**Docker Desktop is not required.** "Docker Desktop" and "Docker" are not the same thing — Desktop
is one way to get a Linux VM running `dockerd`, and OrbStack and Colima are others. All three speak
the same Engine API and ship the same CLI, and nothing in this document uses a Desktop-specific
feature. `docker context ls` is the check that *something* is wired up; on this machine it reports
`orbstack *` with the daemon at `unix:///Users/glenn/.orbstack/run/docker.sock`.

Architecture is worth a glance too — `docker info --format '{{.Architecture}}'`. On Apple Silicon
this reports `aarch64`, and both images used here publish native arm64 variants, so nothing runs
under emulation.

Which Swift is running matters here too, and is pinned by `.swift-version` — see
[`TOOLCHAIN.md`](TOOLCHAIN.md).

Work on a branch so the escape hatch is one command:

```bash
git switch -c postgres
```

If any step below goes badly wrong, `git switch main` puts you back on a working SQLite project
immediately. Don't try to debug forward from a half-migrated state.

---

# Step 1 — The Docker Compose file

Docker is never a Swift dependency. It does not appear in `Package.swift`. It is only how Postgres
gets running, and it shows up in exactly two places: this file, for local development, and the
`services:` block of a GitHub Actions workflow later. **Those two do not share configuration** —
Actions does not read `docker-compose.yml`. The duplication is expected; don't fight it.

Create `docker-compose.yml` in the project root:

```yaml
services:
  db:
    image: postgres:18-alpine
    environment:
      POSTGRES_USER: company_directory
      POSTGRES_PASSWORD: company_directory
      POSTGRES_DB: company_directory
    ports:
      - "5432:5432"
    # Mount /var/lib/postgresql, NOT /var/lib/postgresql/data — see the note below.
    volumes:
      - company_directory_db:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U company_directory -d company_directory"]
      interval: 2s
      timeout: 3s
      retries: 15

  db-test:
    image: postgres:18-alpine
    environment:
      POSTGRES_USER: company_directory
      POSTGRES_PASSWORD: company_directory
      POSTGRES_DB: company_directory_test
    ports:
      - "5433:5432"        # different host port so both servers run at once
    # No *named* volume. The image declares VOLUME /var/lib/postgresql, so Docker still
    # creates an anonymous one — data survives a restart of this container, and is
    # discarded when the container is removed. That is the intent: this database is
    # rebuilt by migrations on every run. The flags below trade crash durability for
    # speed, the right trade for data that is worthless the moment the test finishes.
    command: >-
      postgres -c fsync=off -c full_page_writes=off -c synchronous_commit=off
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U company_directory -d company_directory_test"]
      interval: 2s
      timeout: 3s
      retries: 15

volumes:
  company_directory_db:
```

Three decisions worth understanding rather than copying:

**Pin the major version.** `postgres:18-alpine`, never `postgres:latest`. A silent major bump makes
the named volume's data directory unreadable by the new binary, and the container refuses to start
with an error that does not obviously say so.

**Mount `/var/lib/postgresql`, not `/var/lib/postgresql/data`.** This changed in Postgres 18, and
almost every compose file you will find online still uses the old path. `PGDATA` is now
`/var/lib/postgresql/18/docker` — a major-version-specific subdirectory, so `pg_upgrade --link` can
run without crossing a mount boundary — and the image declares its volume one level up at
`/var/lib/postgresql`. Get this wrong and the container exits immediately with:

```
Error: in 18+, these Docker images are configured to store database data in a
       format which is compatible with "pg_ctlcluster" ...
       Counter to that, there appears to be PostgreSQL data in:
         /var/lib/postgresql/data (unused mount/volume)
```

Refusing to start is the right behaviour: the alternative is booting an empty database while your
real data sits unreachable at the old path. Confirm what the image expects rather than trusting any
example, this one included:

```bash
docker image inspect postgres:18-alpine \
  --format '{{range .Config.Env}}{{println .}}{{end}}{{range $k,$v := .Config.Volumes}}VOLUME {{println $k}}{{end}}' \
  | grep -E 'PGDATA|VOLUME'
```

**The healthcheck is not decoration.** The container reports "running" well before Postgres accepts
connections — the official image starts the server, runs any init scripts, *restarts* it, and only
then listens on the network port. Without `pg_isready`, `docker compose up -d --wait` returns too
early and the first connection fails.

**Two servers rather than two databases on one server.** It lets the test one run with durability
off, and lets you throw it away without touching your development data.

Note that `db-test` still gets a volume, just not a named one — the image declares
`VOLUME /var/lib/postgresql`, so Docker creates an anonymous volume regardless. Its data survives a
container restart and disappears when the container is removed. That is the intent; the difference
from `db` is that nothing named is keeping it alive.

Verify:

```bash
docker compose up -d --wait
docker compose ps            # expect: both services, status "healthy"
docker compose exec db psql -U company_directory -d company_directory -c 'SELECT version();'
```

**That is not a connectivity test, and it is important to know why.** `docker compose exec` runs
`psql` *inside* the container, over its Unix socket. It never touches host networking. A healthy
container plus a working `exec` tells you the database is running and the role exists — and tells
you nothing about whether anything on your Mac can reach it. Vapor connects over TCP to
`localhost:5432`, which is a completely different path.

Test the path the application actually uses:

```bash
PGPASSWORD=company_directory psql -h localhost -p 5432 -U company_directory -d company_directory \
  -tAc "select current_database() || ' @ ' || version();"
```

Expect a version string ending in `aarch64-unknown-linux-musl` (or `x86_64-…-linux-musl`). The
`linux-musl` part is the proof: that is the Alpine container. A macOS-native server would report a
Darwin build, and that difference is the whole point of the check.

No `psql` on the host? Postgres.app leaves one at
`/Applications/Postgres.app/Contents/Versions/latest/bin/psql` even when its server is stopped, and
`brew install libpq` is the other source. Failing that, `docker run --rm postgres:18-alpine psql
"postgresql://company_directory:company_directory@host.docker.internal:5432/company_directory" -c 'select version();'` routes back
out through the host, which exercises the same published port.

### If that connection fails with `role "company_directory" does not exist`

The role exists — you are talking to a different server. Something else on the machine is bound to
5432:

```bash
lsof -nP -iTCP:5432 -sTCP:LISTEN
```

Postgres.app and a Homebrew `postgresql` service both bind loopback (`127.0.0.1` and `[::1]`), while
Docker binds the wildcard `*:5432`. macOS permits that pair to coexist, and for a connection to
`localhost` **the more specific binding wins** — so the native server silently takes the connection
and rejects it with SQLSTATE `28000`, because it has no `company_directory` role. Nothing in the error mentions
ports, so it reads like a credentials problem.

Two fixes. Stop the native server, if you do not need it — which is the right call once this
project's database lives in Docker. Or move the container to a free port (`"5434:5432"`) and set
`DATABASE_PORT` to match, which is the better answer if you need both at once.

Day-to-day commands:

| Command | Effect |
| --- | --- |
| `docker compose up -d --wait` | Start both, block until accepting connections |
| `docker compose up -d --wait db-test` | Start only the test server |
| `docker compose logs -f db` | Follow the server log — where connection errors explain themselves |
| `docker compose down` | Stop; the dev volume survives |
| `docker compose down -v` | Stop and **delete the dev data**. The "clean slate" button |

## Where the data actually lives

Not in the image. Worth untangling, because the distinction decides what is safe to delete.

| | What it is | Lifetime |
| --- | --- | --- |
| **Image** — `postgres:18-alpine` | A read-only template pulled from Docker Hub. Identical on every machine, holds no data, never written to | Until you `docker rmi` it. Re-pulling changes nothing about your data |
| **Container** — `foobar-db-1` | A running instance of that image, plus a thin writable layer | Dies with the container |
| **Volume** — `foobar_foobar_db` | Where PostgreSQL's data directory actually is | Outlives the container. Only `docker compose down -v` removes it |

```bash
docker volume inspect foobar_foobar_db --format '{{.Name}} -> {{.Mountpoint}}'
# foobar_foobar_db -> /var/lib/docker/volumes/foobar_foobar_db/_data
```

That mountpoint is a path **inside the Linux VM**, not on macOS. Compose prefixes the project
directory name onto the volume declared in the file, which is why `company_directory_db` becomes
`foobar_foobar_db`.

OrbStack additionally surfaces it on macOS at `~/OrbStack/docker/volumes/foobar_foobar_db`, so you
can browse it. Do not edit anything there while the server is running — PostgreSQL owns those files
and expects exclusive control. The supported way in is the network port.

## Connecting a GUI client

Postico, TablePlus, DataGrip and friends all work — this is an ordinary PostgreSQL server on a TCP
port, and nothing about Docker changes how clients reach it.

| Field | Development | Test |
| --- | --- | --- |
| Host | `localhost` | `localhost` |
| Port | `5432` | `5433` |
| User | `company_directory` | `company_directory` |
| Password | `company_directory` | `company_directory` |
| Database | `company_directory` | `company_directory_test` |

**SSL must not be set to *require*.** The official image ships no certificates and runs with
`ssl = off`; use *allow* or *prefer*. Confirm with:

```bash
PGPASSWORD=company_directory psql -h localhost -p 5432 -U company_directory -d company_directory -tAc 'show ssl;'
```

Point a client at the test database by all means, but expect nothing to persist: the suite drops
and recreates its tables on every run.

### OrbStack only: reaching containers by name

OrbStack gives every container a DNS name on the host, so you can connect without going through a
published port at all. Two forms work, both verified 2026-08-14:

```
<service>.<project>.orb.local     db.foobar.orb.local        db-test.foobar.orb.local
<container-name>.orb.local        foobar-db-1.orb.local      foobar-db-test-1.orb.local
```

**Use the container's port, not the host mapping.** This is the part that catches people:

| Address | Port | Works |
| --- | --- | --- |
| `localhost` | `5432` / `5433` | Yes — the published mappings |
| `db.foobar.orb.local` | `5432` | Yes |
| `db-test.foobar.orb.local` | **`5432`** | Yes — *not* 5433 |
| either `.orb.local` name | `5433` | **Connection refused** |

`5433` only ever existed as a host-side mapping to avoid a collision on `5432`. Addressing the
container directly bypasses that mapping entirely, and both containers listen on `5432` internally.

```bash
PGPASSWORD=company_directory psql -h db-test.foobar.orb.local -p 5432 -U company_directory -d company_directory_test
```

**Never put these names in committed configuration.** They are an OrbStack feature — they do not
exist on Docker Desktop, on Colima, on a CI runner, or on anyone else's machine. `Database.swift`,
`.env.example` and any GitHub Actions workflow must keep using `localhost` and the published ports.
Treat `.orb.local` as a convenience for ad-hoc connections from a GUI client or a one-off `psql`,
and nothing more.

---

# Step 2 — Swap the driver in `Package.swift`

Replace the SQLite dependency:

```swift
// Remove:
.package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0")
// Add (2.12.0 is current as of 2026-08-14; the 2.x line is the Fluent 4 one):
.package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0")
```

And in the application target's dependencies:

```swift
// Remove:
.product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
// Add:
.product(name: "FluentPostgresDriver", package: "fluent-postgres-driver")
```

Verify:

```bash
swift package resolve
```

The build will now fail, because `Database.swift:2` and `TestHelpers.swift:2` both still
`import FluentSQLiteDriver`. That is expected and is the next two steps.

**Run `swift package clean` before that build.** `resolve` deletes the `fluent-sqlite-driver`
checkout but leaves its compiled `.swiftmodule` orphaned in `.build` — no longer in the graph, so
nothing rebuilds it, and nothing deletes it. The stale import finds it anyway, and the resulting
diagnostic points at the compiler rather than at your code:

```
error: compiled module was created by a newer version of the compiler:
       .build/.../Modules/FluentSQLiteDriver.swiftmodule
```

`clean` discards compiled products while keeping `.build/checkouts`, so nothing is re-fetched. The
full diagnosis is in [`TOOLCHAIN.md`](TOOLCHAIN.md); the short version is that an error naming a
module you did not change, at a path inside `.build`, means clean before debugging.

---

# Step 3 — `Sources/CompanyDirectory/Database.swift`

The current file hardcodes `.sqlite(.memory)` at line 30. The replacement has to be configurable,
because the same binary now needs to reach three different servers over its life: your Mac, CI, and
eventually something real.

Change the import from `FluentSQLiteDriver` to `FluentPostgresDriver`, leave `DatabaseError`
exactly as it is, and replace `configureDatabase`:

```swift
/// Builds the Postgres configuration from the environment.
///
/// `DATABASE_URL` wins when present — that is the form hosting platforms inject. The individual
/// variables are the local-development path, and their defaults match `docker-compose.yml`, so a
/// fresh clone works after `docker compose up -d --wait` with no configuration at all.
private func postgresConfiguration() throws -> DatabaseConfigurationFactory {
    if let url = Environment.get("DATABASE_URL") {
        return try .postgres(url: url)
    }

    return .postgres(
        configuration: .init(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init) ?? 5432,
            username: Environment.get("DATABASE_USERNAME") ?? "company_directory",
            password: Environment.get("DATABASE_PASSWORD") ?? "company_directory",
            database: Environment.get("DATABASE_NAME") ?? "company_directory",
            // Correct for a container on your own machine, and wrong for anything reachable
            // over a network.
            tls: .disable
        )
    )
}

/// Registers the Postgres database, adds every migration, and runs them.
///
/// - Throws: `DatabaseError.migrationFailed` or `DatabaseError.configurationFailed`.
func configureDatabase(application: Application) async throws {
    do {
        application.databases.use(try postgresConfiguration(), as: .psql)

        application.migrations.add([
            Migrations.CreateDepartments(),
            Migrations.CreateEmployees()
        ])

        try await application.autoMigrate()
    } catch {
        // ... unchanged ...
    }
}
```

The doc comment on the old function said "storage is in-memory, so all data is discarded when the
process exits". That is no longer true and is the kind of stale comment that costs someone an hour
later — replace it, as above.

**Two things to verify once the package resolves, rather than take on trust:** whether
`.postgres(url:)` is the `throws` overload in the 2.x line, and what TLS mode it infers from a bare
`postgres://` URL. A URL with no `sslmode` parameter has historically defaulted to *requiring* TLS
in some versions, which fails against a local container that offers none. If it does, append
`?sslmode=disable`.

---

# Step 4 — Environment configuration

Vapor handles this properly out of the box, and the mechanics are worth knowing because they make
the conditional logic you might otherwise write unnecessary.

`Application.make` calls `DotEnvFile.load` (`vapor/Sources/Vapor/Application.swift:176`), which
loads `.env.<environment>` first, then `.env`. That loader calls `setenv` with `overwrite: 0`
(`vapor/Sources/Vapor/Utilities/DotEnv.swift:230`), so **real process environment variables always
beat the file**, and the first file to set a key wins.

That gives exactly the layering you want with no code: `.env` on your laptop, real environment
variables in CI and production.

Add to `.gitignore`:

```
# Local environment
.env
.env.*
!.env.example
```

Commit a `.env.example` so a fresh clone knows what the knobs are:

```bash
# Defaults match docker-compose.yml. Copy to .env only if you need to change something.
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_NAME=company_directory
DATABASE_USERNAME=company_directory
DATABASE_PASSWORD=company_directory
```

---

# Step 5 — Run it, and read the schema Postgres actually built

```bash
docker compose up -d --wait
swift run
```

Expect the migration log to show both migrations running, then the server binding:

```
[FluentKit] [Migrator] Starting prepare  migration=foobar.Migrations.CreateDepartments
[FluentKit] [Migrator] Finished prepare  migration=foobar.Migrations.CreateDepartments
[FluentKit] [Migrator] Starting prepare  migration=foobar.Migrations.CreateEmployees
[FluentKit] [Migrator] Finished prepare  migration=foobar.Migrations.CreateEmployees
[Vapor] Server started on http://127.0.0.1:8080
```

Then, in another terminal, prove the API still works end to end. HTTPie sends JSON by default, so
`key=value` pairs become a JSON body with no quoting or `Content-Type` header to get right, and
`:8080` expands to `localhost:8080`:

```bash
http POST :8080/api/departments name=Engineering
http POST :8080/api/departments name="Customer Support"
http :8080/api/departments                            # GET is the default
```

Add `--print=hb` to see the status line and headers alongside the body, and `--ignore-stdin` when
running from a script or anywhere stdin is not a terminal — otherwise HTTPie assumes stdin is the
request body and refuses to mix it with `key=value` items.

Verified output, 2026-08-14:

```
$ http --print=hb POST :8080/api/departments name=Engineering
HTTP/1.1 201 Created
Content-Type: application/json; charset=utf-8

{ "id" : 1, "name" : "Engineering" }

$ http --print=hb POST :8080/api/departments name=Engineering
HTTP/1.1 409 Conflict

{ "error" : true, "reason" : "A department with the name 'Engineering' already exists" }
```

**Now the part with actual learning value in it:** look at the schema Fluent generated.

```bash
docker compose exec db psql -U company_directory -d company_directory -c '\d departments'
```

## Result, verified 2026-08-14

All three open questions came back clean. Recorded here so they do not have to be re-asked:

```
                          Table "public.departments"
   Column    |           Type           | Nullable |             Default
-------------+--------------------------+----------+----------------------------------
 id          | integer                  | not null | generated by default as identity
 name        | text                     | not null |
 inserted_at | timestamp with time zone |          |
 updated_at  | timestamp with time zone |          |
Indexes:
    "departments_pkey" PRIMARY KEY, btree (id)
    "uq:departments.name" UNIQUE CONSTRAINT, btree (name)
```

| Checked | Result | Why it mattered |
| --- | --- | --- |
| `id` | `generated by default as identity` ✓ | `.identifier(auto: true)` is free on SQLite, where any `INTEGER PRIMARY KEY` auto-increments. Postgres needs an explicit identity or sequence, and a bare `integer` with no default would have failed on the second insert. FluentPostgresDriver emits it correctly — no migration change needed |
| `inserted_at`, `updated_at` | `timestamp with time zone` ✓ | Fluent's `.datetime` maps to `TIMESTAMPTZ`. SQLite has no date type and stored these as text; this is the first time they have had a real one |
| `name` | `text`, not null, with `uq:departments.name` as a UNIQUE CONSTRAINT ✓ | The comment at `Migrations.swift:11-14` calls this load-bearing for correctness — it is what stops the read-then-write race in `createDepartment` from producing duplicates |

`employees` is identical minus the unique constraint, and has no `department_id` — correct, that
arrives in Phase 2.

**One thing this run exposed.** The list endpoint returned rows in `id` order, but that is
incidental. Postgres guarantees no ordering without an `ORDER BY`, and neither `listDepartments`
nor `listEmployees` calls `.sort()`. It will hold until the first `PATCH` moves a row within the
heap. See the ordering note under *Differences from SQLite that can bite* — the fix belongs in the
handler, not the tests.

**Checkpoint.** The application runs against Postgres. Tests are still broken. Commit here — this is
a coherent, revertible state.

---

# Step 6 — The test harness, which is the real cost

This has nothing to do with Docker, and it is the only genuinely hard part of the migration.

`TestHelpers.withApplication` currently gets isolation **for free**. `.sqlite(.memory)` at
`TestHelpers.swift:22` creates a brand-new private database per `Application`, which is why the doc
comment on line 15 can say "each call gets its own database, so tests are isolated and can assume an
empty schema".

Postgres has no equivalent. There is one server, Swift Testing runs tests **in parallel by default**,
and the `autoRevert()` at line 27 drops tables out from under whichever tests are still running.
Ignore this and you get a suite that fails differently on every run — the worst possible failure
mode, because it teaches you to distrust the tests rather than the code.

## 6a — First, make the database injectable

**Check this before running `swift test` even once.** `configureServer` calls
`configureDatabase(application:)` itself (`ServerService.swift:11`), so registering a database in
`TestHelpers` before calling it achieves nothing — `configureDatabase` runs afterwards and its
registration wins.

Under SQLite that was invisible. The helper registered `.sqlite(.memory)`, then `configureDatabase`
registered `.sqlite(.memory)` again over the top: the same thing twice, no observable difference,
and the helper's line was pure redundancy nobody had reason to notice.

With Postgres the default resolves to **the development database**, and `withApplication` calls
`autoRevert()` when each test finishes. Run the suite in that state and it drops your development
schema. Nothing warns you; the tests pass.

So the first change is to production code, not test code — make the database an injectable
parameter with the environment-derived one as its default:

```swift
// Database.swift
func configureDatabase(
    application: Application,
    configuration: DatabaseConfigurationFactory? = nil
) async throws {
    do {
        application.databases.use(try configuration ?? postgresConfiguration(), as: .psql)
        // ...

// ServerService.swift
func configureServer(
    _ application: Application,
    databaseConfiguration: DatabaseConfigurationFactory? = nil
) async throws -> Service {
    try await configureDatabase(application: application, configuration: databaseConfiguration)
    // ...
```

Both parameters default, so `Entrypoint.swift` is untouched. This is worth understanding as a
design point rather than a workaround: configuration that a function reaches out and fetches for
itself cannot be varied by a caller, and "the tests cannot choose their own database" is that
problem showing up with real consequences.

## 6b — Then serialize

Two more changes. Start here; do not build the clever version until the simple one is demonstrably
too slow.

`APIHandlerTests.swift` — add the trait, and drop the now-unused `import FluentSQLiteDriver`:

```swift
@Suite("API Handler Integration Tests", .serialized)
```

`TestHelpers.swift` — import `FluentPostgresDriver`, and pass the test database in explicitly
instead of registering one that would be overwritten:

```swift
private static func databaseConfiguration() -> DatabaseConfigurationFactory {
    .postgres(
        configuration: .init(
            hostname: Environment.get("TEST_DATABASE_HOST") ?? "localhost",
            port: Environment.get("TEST_DATABASE_PORT").flatMap(Int.init) ?? 5433,
            username: "company_directory",
            password: "company_directory",
            database: "company_directory_test",
            tls: .disable
        )
    )
}

// in withApplication, replacing the databases.use call:
try await configureServer(application, databaseConfiguration: databaseConfiguration())
```

The port defaults to **5433**, the `db-test` mapping from step 1, and host and port are overridable
so CI can point elsewhere without a code change. The database *name* is deliberately not
overridable: a misconfigured port then fails to connect rather than reaching the development
database.

The `autoRevert()`-then-`asyncShutdown()` structure is unchanged but its meaning is not. It used to
be tidy-up on a database that was about to evaporate anyway; it is now the only thing giving the
next test an empty schema. Along with `.serialized`, it is one of two halves of the isolation —
remove either and tests interfere. Both deserve a comment saying so, and the helper's
"fresh in-memory database" doc comment needs correcting.

## 6c — Database per test, later

When serialization starts to hurt, the upgrade is: generate a unique database name per test,
`CREATE DATABASE` it through a connection to the maintenance `postgres` database, migrate, run the
test, drop it. Full isolation, parallelism restored, roughly 50–150ms of overhead per test.

Two notes for when you get there: `CREATE DATABASE` cannot take a bound parameter, so build the
statement with SQLKit's `\(ident:)` interpolation rather than string concatenation; and once it
works, `CREATE DATABASE … TEMPLATE company_directory_test_template` from a pre-migrated template skips
re-running migrations per test.

---

# Step 7 — Run the suite

```bash
docker compose up -d --wait db-test
swift test
```

**Result, 2026-08-14:** `Test run with 14 tests in 1 suite passed after 1.520 seconds.`

Serialized execution costs so little at this size that step 6c stays firmly hypothetical. Revisit
it when the suite is large enough for the wall-clock to matter, not before.

Then prove the development database was not collateral damage — the whole point of 6a:

```bash
PGPASSWORD=company_directory psql -h localhost -p 5432 -U company_directory -d company_directory \
  -c '\dt' -c 'select * from departments;'
```

Its tables and rows should be exactly as you left them. The test database, by contrast, should have
only `_fluent_migrations` left, every other table having been dropped by the final `autoRevert()`:

```bash
PGPASSWORD=company_directory psql -h localhost -p 5433 -U company_directory -d company_directory_test -c '\dt'
```

If a test fails, check it against the differences below before assuming the migration broke
something.

---

# Differences from SQLite that can bite

**Row ordering is not guaranteed.** Neither `listDepartments` (`APIHandler.swift:15`) nor
`listEmployees` (`:140`) has a `.sort()`. SQLite returns rows in rowid order in practice, so tests
that index into a list have quietly worked. Postgres makes no such promise, and an updated row
physically moves within the heap — so a list can come back in a different order after a `PATCH`.

The suite survives this today by luck: `APIHandlerTests.swift:202` reads
`departments.first?.name == "Engineering"` but only after a delete has left exactly one row. That
luck runs out as soon as Phase 1 adds more list tests. The fix belongs in the handler, not the
tests — add `.sort(\.$id)` — because unordered list endpoints are a real API defect regardless of
which database is underneath.

**Unique-violation errors read completely differently.** Nothing depends on this today, as noted at
the top. Keep it that way: if you ever need to catch a constraint violation, match on
`PostgresError`'s SQLSTATE code `23505`, never on the message text.

**Timestamps now have a type.** SQLite stored `inserted_at` and `updated_at` as text and would
accept nearly anything. Postgres will reject values that are not timestamps. This should not
surface — Fluent's `@Timestamp` handles the conversion — but it means a class of bug that SQLite
silently absorbed is now a hard error, which is the point of the exercise.

**Migrations now run against a database that already has data.** Every migration so far has run
against an empty schema, which is the easy case. The dev database persists across restarts, so the
next migration you write will be the first real one. This is a feature — and it paid off
immediately: see [`MIGRATIONS.md`](MIGRATIONS.md), where the very next migration failed on existing
rows.

---

# What this unlocks

**Immediately:** the Phase 2 test from [`API-DESIGN.md`](API-DESIGN.md) §2.3 — insert an employee
whose `department_id` matches no department, and watch it *fail*, where SQLite would have let it
through. Write that test before writing the relationship.

**Next:** CI. **Done 2026-08-15** — `.github/workflows/ci.yml`, issue #1. The playbook for running
it is [`CI.md`](CI.md).

A GitHub Actions workflow declares Postgres in its own `services:` block, not from
`docker-compose.yml`. The gotchas there are that a job running in a `container:` reaches the service
at hostname `postgres` on port **5432** (the container port, not a mapped one) with no `ports:`
mapping at all, while a job running directly on the runner needs `ports:` and `localhost`; and that
**macOS runners have no Docker daemon and cannot use `services:` at all**, so this has to be a Linux
job.

Which raised the one thing to check early, since this project had only ever been built on macOS:

```bash
docker run --rm -v "$PWD":/src -w /src -v /tmp/company-directory-linux-build:/build \
  swift:6.3.3 swift build --scratch-path /build
```

The `platforms: [.macOS(.v26)]` line in `Package.swift` is ignored on Linux and does not block the
build. Vapor and Fluent are Linux-first, so this was expected to pass — but the first CI run is a
bad place to find out otherwise.

**It passed**, and so did `swift test`, 14/14, against `db-test` reached over the compose network.
No conditional imports were needed anywhere; there is no `Darwin` or `FoundationNetworking` in this
codebase. The full image also ships `swift-format` 6.3.3, so the lint step in #6 needs no install.

Two things learned doing it:

- **`--scratch-path` is mandatory**, not hygiene. Without it the container writes Linux modules into
  the macOS `.build` — the [`TOOLCHAIN.md`](TOOLCHAIN.md) corruption, with an architecture mismatch
  on top.
- **`swift:6.3.3-slim` will not work.** The slim variants ship the runtime only and have no
  compiler.

One gap remains, deliberately: this was verified on **aarch64**, because OrbStack runs the arm64
image natively. `ubuntu-latest` is amd64. The failure class being hunted here — Glibc and Foundation
divergence — is architecture-independent, so the residual risk is low and CI itself is the amd64
check.

The routine for running this check locally, and when it is worth the 92 seconds, is in
[`WORKFLOW.md`](WORKFLOW.md) → *Where the checks run*.
