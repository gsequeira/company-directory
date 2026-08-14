# Moving from SQLite to PostgreSQL

A step-by-step migration from the in-memory SQLite database to PostgreSQL running in Docker, with
a verification checkpoint after every step.

**Status as of 2026-08-14:** not started. This is step 3 of the sequence in
[`LEARNING-PATH.md`](LEARNING-PATH.md), pulled forward ahead of CI because a CI workflow written
against SQLite would be rewritten a week later.

Companion documents: [`LEARNING-PATH.md`](LEARNING-PATH.md) explains *why* this move is worth
making early, [`API-DESIGN.md`](API-DESIGN.md) §2.3 is the foreign-key problem that motivates it,
and [`TESTING.md`](TESTING.md) holds the assertion conventions the new test harness must keep
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
| `Sources/foobar/Database.swift` | Driver swap, connection read from the environment | Low |
| `Tests/foobarTests/TestHelpers.swift` | Loses free per-test isolation | **This is the real work** |
| `Tests/foobarTests/APIHandlerTests.swift` | One trait added to `@Suite` | Low |
| `.gitignore` | Ignore `.env` | None |

`Sources/foobar/APIHandler.swift`, `Models.swift` and `Migrations.swift` need **no changes**. Worth
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
swift test 2>&1 | tail -5   # expect: 14/14 passing
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
      POSTGRES_USER: foobar
      POSTGRES_PASSWORD: foobar
      POSTGRES_DB: foobar
    ports:
      - "5432:5432"
    # Mount /var/lib/postgresql, NOT /var/lib/postgresql/data — see the note below.
    volumes:
      - foobar_db:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U foobar -d foobar"]
      interval: 2s
      timeout: 3s
      retries: 15

  db-test:
    image: postgres:18-alpine
    environment:
      POSTGRES_USER: foobar
      POSTGRES_PASSWORD: foobar
      POSTGRES_DB: foobar_test
    ports:
      - "5433:5432"        # different host port so both servers run at once
    # No volume: this database is disposable by design, recreated by migrations on every
    # run. These flags trade crash durability for speed, which is the right trade for data
    # that is worthless the moment the test finishes.
    command: >-
      postgres -c fsync=off -c full_page_writes=off -c synchronous_commit=off
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U foobar -d foobar_test"]
      interval: 2s
      timeout: 3s
      retries: 15

volumes:
  foobar_db:
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

Verify:

```bash
docker compose up -d --wait
docker compose ps            # expect: both services, status "healthy"
docker compose exec db psql -U foobar -d foobar -c 'SELECT version();'
```

Day-to-day commands:

| Command | Effect |
| --- | --- |
| `docker compose up -d --wait` | Start both, block until accepting connections |
| `docker compose up -d --wait db-test` | Start only the test server |
| `docker compose logs -f db` | Follow the server log — where connection errors explain themselves |
| `docker compose down` | Stop; the dev volume survives |
| `docker compose down -v` | Stop and **delete the dev data**. The "clean slate" button |

---

# Step 2 — Swap the driver in `Package.swift`

Replace the SQLite dependency:

```swift
// Remove:
.package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0")
// Add (2.12.0 is current as of 2026-08-14; the 2.x line is the Fluent 4 one):
.package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0")
```

And in the `foobar` target's dependencies:

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

---

# Step 3 — `Sources/foobar/Database.swift`

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
            username: Environment.get("DATABASE_USERNAME") ?? "foobar",
            password: Environment.get("DATABASE_PASSWORD") ?? "foobar",
            database: Environment.get("DATABASE_NAME") ?? "foobar",
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
DATABASE_NAME=foobar
DATABASE_USERNAME=foobar
DATABASE_PASSWORD=foobar
```

---

# Step 5 — Run it, and read the schema Postgres actually built

```bash
docker compose up -d --wait
swift run
```

Expect the migration log to show both migrations running, then the server binding. Then, in another
terminal, prove the API still works end to end:

```bash
curl -s -X POST localhost:8080/api/departments \
  -H 'content-type: application/json' -d '{"name":"Engineering"}'
curl -s localhost:8080/api/departments
```

**Now do the part that has actual learning value in it:** look at the schema Fluent generated.

```bash
docker compose exec db psql -U foobar -d foobar -c '\d departments'
```

What to check, and why each one matters:

| Column | Expect | Why it matters |
| --- | --- | --- |
| `id` | `integer`, not null, `generated by default as identity` (or `nextval(...)`) | `.identifier(auto: true)` is free on SQLite, where any `INTEGER PRIMARY KEY` auto-increments. Postgres needs an explicit identity or sequence. If it is a plain `integer` with no default, inserts will fail on the second row and the migration needs fixing |
| `inserted_at`, `updated_at` | `timestamp with time zone` | Fluent's `.datetime` maps to `TIMESTAMPTZ`. SQLite has no date type at all and stored these as text — this is the first time they have had a real type |
| `name` | `character varying`/`text`, not null | Plus a unique index, listed under `Indexes:` |

The unique index is the one to confirm explicitly, because the comment at `Migrations.swift:11-14`
says it is load-bearing for correctness — it is what stops the read-then-write race in
`createDepartment` from producing duplicates:

```bash
docker compose exec db psql -U foobar -d foobar -c '\d departments' | grep -i unique
```

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

## 6a — Serialize first

With 14 tests this costs seconds, and it is two small changes. Start here; do not build the clever
version until the simple one is demonstrably too slow.

`APIHandlerTests.swift:11`:

```swift
@Suite("API Handler Integration Tests", .serialized)
```

`TestHelpers.swift` — change the import to `FluentPostgresDriver` and replace line 22:

```swift
application.databases.use(
    .postgres(
        configuration: .init(
            hostname: Environment.get("TEST_DATABASE_HOST") ?? "localhost",
            port: Environment.get("TEST_DATABASE_PORT").flatMap(Int.init) ?? 5433,
            username: "foobar",
            password: "foobar",
            database: "foobar_test",
            tls: .disable
        )
    ),
    as: .psql
)
```

Note the port defaults to **5433** — the `db-test` mapping from step 1 — and that both host and port
are overridable, so CI can point elsewhere without a code change.

The existing `autoRevert()`-then-`asyncShutdown()` structure still works, but its meaning has
changed: it used to be tidy-up on a database that was about to evaporate anyway, and it is now the
only thing giving the next test an empty schema. Worth saying so in the doc comment, which also
needs its "fresh in-memory database" claim corrected.

Distinct `TEST_DATABASE_*` names are deliberate. `Application.make(.testing)` loads `.env.testing`
before `.env`, so reusing `DATABASE_HOST` for both would work but would depend on file-precedence
rules to keep the test run off your development data. A wrong answer there truncates the wrong
database.

## 6b — Database per test, later

When serialization starts to hurt, the upgrade is: generate a unique database name per test,
`CREATE DATABASE` it through a connection to the maintenance `postgres` database, migrate, run the
test, drop it. Full isolation, parallelism restored, roughly 50–150ms of overhead per test.

Two notes for when you get there: `CREATE DATABASE` cannot take a bound parameter, so build the
statement with SQLKit's `\(ident:)` interpolation rather than string concatenation; and once it
works, `CREATE DATABASE … TEMPLATE foobar_test_template` from a pre-migrated template skips
re-running migrations per test.

---

# Step 7 — Run the suite

```bash
docker compose up -d --wait db-test
swift test
```

Expect 14/14. If a test fails, check it against the differences below before assuming the migration
broke something.

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
next migration you write will be the first real one. This is a feature.

---

# What this unlocks

**Immediately:** the Phase 2 test from [`API-DESIGN.md`](API-DESIGN.md) §2.3 — insert an employee
whose `department_id` matches no department, and watch it *fail*, where SQLite would have let it
through. Write that test before writing the relationship.

**Next:** CI. A GitHub Actions workflow declares Postgres in its own `services:` block, not from
`docker-compose.yml`. The gotchas there are that a job running in a `container:` reaches the service
at hostname `postgres` on port **5432** (the container port, not a mapped one) with no `ports:`
mapping at all, while a job running directly on the runner needs `ports:` and `localhost`; and that
**macOS runners have no Docker daemon and cannot use `services:` at all**, so this has to be a Linux
job.

Which raises the one thing to check early, since this project has only ever been built on macOS:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.3 swift build
```

The `platforms: [.macOS(.v26)]` line in `Package.swift` is ignored on Linux and will not block the
build. Vapor and Fluent are Linux-first, so this is expected to pass — but the first CI run is a bad
place to find out otherwise.
