# Migrations

How schema changes are made in this project, and what a migration against a database that already
contains data actually behaves like.

**Written 2026-08-14**, from a worked example: adding the unique constraint behind
`createEmployee`'s 409. That migration failed on the first attempt, which is the reason this
document exists — the first four migrations in this project all ran against an empty schema, which
is the easy case and teaches almost nothing.

Companion documents: [`POSTGRES.md`](POSTGRES.md) is how the database got here,
[`API-DESIGN.md`](API-DESIGN.md) holds the design decisions a migration implements, and
[`TESTING.md`](TESTING.md) covers the suite that exercises `revert` on every run.

## The three rules

**1. Append, never amend.** Once a migration has run anywhere — including your own development
database — it is history. Fluent records each applied migration in the `_fluent_migrations` table
and skips anything already listed, so editing an existing migration changes nothing on any database
where it has already been applied. It only affects databases created from scratch afterwards, which
is the worst possible outcome: two databases with the same migration list and different schemas.

**2. `.update()` for an existing table, `.create()` for a new one.** `.create()` on a table that
exists fails; `.update()` emits `ALTER TABLE`.

**3. Write the data query before the migration.** Any constraint you add can be violated by rows
that are already there. Find out first:

```sql
-- Before adding a unique constraint on (first_name, last_name):
select first_name, last_name, count(*) as copies, array_agg(id order by id) as ids
from employees
group by first_name, last_name
having count(*) > 1;
```

If that returns rows, you have a **data** problem to solve before you have a schema problem, and
the decision — delete, merge, or rename — is a product decision, not a technical one.

## Anatomy

Migrations live in `Sources/foobar/Migrations.swift` as members of the `Migrations` enum:

```swift
struct AddEmployeeNameUniqueness: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Models.Employee.schema)
            .unique(on: "first_name", "last_name")
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Models.Employee.schema)
            .deleteUnique(on: "first_name", "last_name")
            .update()
    }
}
```

`revert` is not optional in practice. It is what the test suite runs after every single test — see
*Revert is already tested* below — so a wrong `revert` breaks the suite immediately.

Register it in `Database.swift`, appending to the list:

```swift
application.migrations.add([
    Migrations.CreateDepartments(),
    Migrations.CreateEmployees(),
    Migrations.AddEmployeeNameUniqueness()
])
```

Order matters and is append-only. `autoMigrate()` runs the ones not yet recorded, in list order.

### Constraint names are generated

Fluent derives them, and you will see these names in error messages, so they are worth being able
to predict. From `FluentSQL/SQLSchemaConverter.swift:127`:

```
prefix ":" table "." column ["+" table "." column ...]
```

giving `uq:employees.first_name+employees.last_name`, and `fk:` for foreign keys. `unique(on:)`
takes an optional `name:` if you want to choose your own.

---

# Worked example: adding uniqueness to `employees`

## The starting condition

`createEmployee` returned 409 for a duplicate name, enforced only by a pre-check query in the
handler, with no constraint behind it. Two concurrent requests could both pass the check and both
insert. To reproduce a realistic "table already has bad data" situation — realistic precisely
because nothing prevented it — the duplicates went in directly:

```sql
insert into employees (first_name, last_name, inserted_at, updated_at) values
  ('Jane','Doe', now(), now()),
  ('Jane','Doe', now(), now()),
  ('Ada','Lovelace', now(), now());
```

That succeeding is itself the proof the constraint was missing.

## The migration fails

```
[Migrator] Starting prepare  migration=foobar.Migrations.AddEmployeeNameUniqueness
error=PSQLError(code: server, serverInfo: [
    sqlState: 23505,
    detail: Key (first_name, last_name)=(Jane, Doe) is duplicated.,
    message: could not create unique index "uq:employees.first_name+employees.last_name",
    schemaName: public, tableName: employees],
  query: ALTER TABLE "employees" ADD CONSTRAINT
         "uq:employees.first_name+employees.last_name" UNIQUE ("first_name", "last_name"))
[Migrator] Failed prepare
error=configurationFailed(...) [foobar] Application startup failed
```

Three things to take from that output.

**The application refused to start.** `configureDatabase` throws, `Entrypoint` catches, logs and
exits 1. That is the right behaviour — a server running against a half-migrated schema is worse
than a server that is down.

**The generated SQL is right there in the error.** `query:` shows exactly what Fluent emitted. When
a migration does something unexpected, this is the first place to look, ahead of any guessing about
what the DSL means.

**SQLSTATE `23505` is the unique-violation code.** Match on that, never on the message text — see
*What this did not fix* below.

## What the failure left behind: nothing

```
Indexes:
    "employees_pkey" PRIMARY KEY, btree (id)

_fluent_migrations:
    foobar.Migrations.CreateEmployees     batch 1
    foobar.Migrations.CreateDepartments   batch 1
```

No constraint, and no row recording the attempt. **PostgreSQL runs DDL inside transactions**, so
the failed `ALTER TABLE` took itself with it, and the migration stayed cleanly re-runnable.

This is not universal and is worth knowing as a PostgreSQL property rather than a general one.
MySQL does not have transactional DDL; a failure part-way through leaves the schema in whatever
state it reached, and recovering means inspecting the table to work out how far it got.

## Fix the data, then re-run

```sql
delete from employees e using employees keep
where e.first_name = keep.first_name
  and e.last_name  = keep.last_name
  and e.id > keep.id;
```

Keeping the lowest `id` of each group is the right call *here* because the rows are development
seed data. In production this is where the real work is — deciding which record is canonical,
whether the others have references pointing at them, and whether anyone needs to be told.

Second run:

```
[Migrator] Starting prepare  migration=foobar.Migrations.AddEmployeeNameUniqueness
[Migrator] Finished prepare
[Vapor] Server started on http://127.0.0.1:8080
```

Only the new migration ran. `CreateDepartments` and `CreateEmployees` were skipped because
`_fluent_migrations` already lists them — rule 1 in action.

## The result

```
Indexes:
    "employees_pkey" PRIMARY KEY, btree (id)
    "uq:employees.first_name+employees.last_name" UNIQUE CONSTRAINT, btree (first_name, last_name)

_fluent_migrations:
    foobar.Migrations.CreateDepartments           batch 1
    foobar.Migrations.CreateEmployees             batch 1
    foobar.Migrations.AddEmployeeNameUniqueness   batch 2
```

And it enforces:

```
ERROR:  duplicate key value violates unique constraint
        "uq:employees.first_name+employees.last_name"
DETAIL: Key (first_name, last_name)=(Jane, Doe) already exists.
```

**Do this check every time.** A migration that reports success has told you it ran, not that it did
what you meant. Reading the schema back, and provoking the constraint, is what confirms intent.

---

# Batches

The `batch` column is the unit of `revert`, not the individual migration. Everything applied by one
`autoMigrate()` run shares a batch number, and a revert undoes the most recent batch as a group.

Both original migrations are batch 1 because they were applied together. This one is batch 2
because it ran on its own. Add three migrations at once and all three share a batch — reverting
then undoes all three, which is usually what you want and occasionally a surprise.

# Revert is already tested

There is no separate test for `revert`, and there does not need to be:
`TestHelpers.withApplication` calls `autoRevert()` after every test, which reverts every migration
in reverse order. The suite exercises `AddEmployeeNameUniqueness.revert` fourteen times per run. A
wrong `revert` fails the suite immediately rather than lying dormant until the day you need it.

This is a nice property to preserve — it is a direct consequence of the test harness rebuilding the
schema per test, described in [`POSTGRES.md`](POSTGRES.md) step 6.

---

# What this did not fix

The constraint makes the database honest. It does not make the API honest.

`createEmployee` still produces its 409 from the pre-check at `APIHandler.swift:165`, and nothing
maps a constraint violation to a response — the handler ends in `catch { throw error }`. So the
losing side of a genuine race now gets a **500**, not a 409. The database rejects the write
correctly; the client is told the wrong thing about why.

`createDepartment` has had the identical gap since the beginning. The comment at
`APIHandler.swift:33-36` says the unique index "is what actually prevents the duplicate, by failing
the second insert" — accurate, and that failure surfaces as a 500.

The fix is to catch the violation and map it, keying on the SQLSTATE rather than the message:

```swift
// Sketch — 23505 is unique_violation.
catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
    return .conflict(.init(body: .json(...)))
}
```

Worth doing for both handlers together, at which point the pre-checks become an optimisation that
produces a friendlier message in the common case, rather than the only thing standing between a
client and a 500. Not yet done.

*(Derived from reading the code; a genuine race is hard to trigger deliberately. Confirm it by
provoking the violation directly before relying on the reasoning.)*

# Not yet encountered

Things this project has not had to deal with, listed so they are not a surprise later:

| Situation | Why it is harder than it looks |
| --- | --- |
| **Adding a `NOT NULL` column to a populated table** | Every existing row needs a value. Usually three migrations: add nullable, backfill, then add the constraint |
| **Long-held locks** | `ALTER TABLE ADD CONSTRAINT UNIQUE` takes an `ACCESS EXCLUSIVE` lock and builds the index while holding it. Fine on two rows; on a large table it blocks all reads and writes for the duration. PostgreSQL's answer is `CREATE UNIQUE INDEX CONCURRENTLY`, which Fluent's schema builder does not expose — reach for raw SQL via `SQLDatabase` when it matters |
| **Data migrations** | Migrations that move or transform rows rather than change shape. `prepare` can run queries, not just schema changes — and a `revert` that genuinely restores the old data is often impossible, which is worth admitting in the code rather than faking |
| **Renaming a column** | Fluent has `updateField`, but a rename is a breaking change for anything reading the old name. Usually staged: add, dual-write, backfill, drop |
| **Migrating on deploy** | `autoMigrate()` runs at startup here. With more than one instance starting at once, they race. Production systems usually run migrations as a separate step before the new version starts |

# Checklist

- [ ] New migration, not an edit to an existing one.
- [ ] `.update()` for an existing table, `.create()` for a new one.
- [ ] `revert` written and genuinely undoes `prepare`.
- [ ] Appended to the list in `Database.swift`.
- [ ] Queried for data that would violate the new constraint, before running it.
- [ ] Ran it, then read the schema back to confirm it did what you meant.
- [ ] Provoked the new constraint to confirm it is enforced.
- [ ] `swift test` passes — which also exercises `revert`.
