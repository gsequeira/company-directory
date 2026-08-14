# The Fluent stack

What "Fluent" actually is, where a database error comes from, and why catching one looks the way it
does in `APIHandler`.

**Written 2026-08-14**, from working out how to map a unique-constraint violation to a `409`. That
one line of `catch` turned out to need most of this document to justify, which is a good sign it
was worth writing down.

Companion documents: [`POSTGRES.md`](POSTGRES.md) is how this project got onto PostgreSQL,
[`MIGRATIONS.md`](MIGRATIONS.md) covers schema changes.

## Fluent is not one module

`import Fluent` is a stack, not a library. `fluent/Sources/Fluent/Exports.swift` is one line:

```swift
@_exported import FluentKit
```

Everything you think of as Fluent — `Model`, `@Field`, `@ID`, `QueryBuilder`, `Migration` — is
`FluentKit`. The `Fluent` module itself only adds the Vapor integration: `app.db`, the `migrate`
command, `application.migrations`, and the session and authentication helpers.

```
your handler
  Fluent                  Vapor integration — app.db, migrate command, auth/session helpers
    └ FluentKit           the ORM proper — Model, @Field, QueryBuilder, Migration, DatabaseError
  FluentPostgresDriver    the adapter — makes PostgreSQL look like a FluentKit Database
    └ PostgresKit         SQLKit + PostgresNIO glue
        └ PostgresNIO     the wire protocol — PSQLError lives here
    └ SQLKit              generic SQL builder; FluentSQL translates FluentKit queries into it
```

**FluentKit knows nothing about PostgreSQL.** That is the design, and it is why swapping the driver
in [`POSTGRES.md`](POSTGRES.md) step 2 did not touch a single model or query. The driver package is
an adapter and nothing else.

Because of `@_exported import`, `import Fluent` puts every FluentKit name in scope *and* makes
`FluentKit` usable as a qualifier. An explicit `import FluentKit` adds nothing — verified by
deleting it and rebuilding.

## Where a database error comes from

This is the part that makes the rest make sense. When `newDepartment.save(on: database)` hits a
unique-constraint violation:

1. FluentKit builds a `DatabaseQuery`.
2. FluentPostgresDriver, via FluentSQL and SQLKit, turns it into SQL.
3. PostgresNIO sends it. The server replies with an error carrying SQLSTATE `23505`.
4. **PostgresNIO throws `PSQLError`** — a PostgresNIO type.
5. It propagates up through FluentKit **unchanged**. Fluent does not wrap it.

So the error your `catch` receives is not a Fluent error at all. It belongs to a module three
layers down that your code never imports. Naively, inspecting it would mean importing PostgresNIO
into the handler and knowing SQLSTATE codes — which would put PostgreSQL back into the one place
the layering exists to keep it out of.

## The trick: retroactive conformance

`fluent-postgres-driver/Sources/FluentPostgresDriver/PostgresError+Database.swift`:

```swift
extension PostgresError: @retroactive DatabaseError {}
extension PSQLError:     @retroactive DatabaseError {}
```

Three parts working together:

- **FluentKit declares the vocabulary.** `DatabaseError` is a three-property protocol —
  `isSyntaxError`, `isConstraintFailure`, `isConnectionClosed`.
- **The driver supplies the conformance**, translating SQLSTATE into those booleans.
- **Your code depends only on the vocabulary.**

Which is why this compiles in a file with no PostgreSQL import, and would keep working on MySQL or
SQLite — each driver ships its own conformance:

```swift
} catch let error as any FluentKit.DatabaseError where error.isConstraintFailure {
```

`@retroactive` is Swift 6 making you acknowledge that you are conforming a type you do not own to a
protocol you do not own. It is an acknowledged-fragile move: if PostgresNIO ever declared its own
`DatabaseError` conformance, the two would collide.

## Why the `FluentKit.` qualifier

Originally it was mandatory. `Database.swift` declared its own `enum DatabaseError`, and inside
module `foobar` an unqualified name resolves to the module's own declaration first. Without the
qualifier the compiler said:

```
error: 'any' has no effect on concrete type 'DatabaseError'
error: value of type 'DatabaseError' has no member 'isConstraintFailure'
```

Worth noticing how *loudly* that failed. `any` is meaningless on a concrete type, so the compiler
stopped. Had the local type been a protocol, this would have compiled and silently never matched —
a `catch` clause that looks right and never fires.

That enum has since been renamed `DatabaseSetupError`, which is a better name anyway: it describes
startup failures from `configureDatabase`, not database errors generally. The qualifier is
therefore no longer required.

**It is kept deliberately.** This file catches an error type originating three modules away in a
stack the reader may not have in their head, and `FluentKit.DatabaseError` says so at the point of
use. It also stops the collision reappearing silently if someone adds a `DatabaseError` later.

## What the abstraction costs

`isConstraintFailure` is true for *every* constraint type:

```
integrityConstraintViolation, restrictViolation, notNullViolation,
foreignKeyViolation, uniqueViolation, checkViolation, exclusionViolation
```

The protocol cannot tell you *which*. That is fine today, because uniqueness is the only constraint
on these tables — so a constraint failure during `createDepartment` can only mean a duplicate name.

**Phase 2 breaks this.** Once `employees.department_id` has a foreign key, a request naming a
department that does not exist raises a `foreignKeyViolation`, which this code would report as
"An employee named X already exists". Wrong, and confusingly so.

At that point the choice is:

| Option | Cost |
| --- | --- |
| Match SQLSTATE `23505` directly | `import PostgresNIO` in the handler; portability lost |
| Inspect the constraint name in the error | Also driver-specific, and depends on Fluent's generated names |
| Look up the department before saving | An extra query, and it races too — but the failure mode is a `404`, which is at least the right answer |

None is free. The comment in `APIHandler` names the hazard so it is not discovered by a confused
user.

## Reading the source is the fastest way

Everything above was established by reading `.build/checkouts`, not documentation. That directory
is the real reference for this stack:

```bash
grep -rn "isConstraintFailure" .build/checkouts/
sed -n 50,80p .build/checkouts/fluent-postgres-driver/Sources/FluentPostgresDriver/PostgresError+Database.swift
cat .build/checkouts/fluent/Sources/Fluent/Exports.swift
```

Fluent's API documentation is thin on exactly this kind of question — which types cross which
boundary, and what a driver adds to the core. The checkouts answer it in seconds and cannot be out
of date, because they are the version you are compiling against.
