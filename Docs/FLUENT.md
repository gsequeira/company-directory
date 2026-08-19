# The Fluent stack

What "Fluent" actually is, where a database error comes from, and why catching one looks the way it
does in `APIHandler`.


> **Renamed 2026-08-16.** This project was called `foobar` until the module became
> `CompanyDirectory`. Captured output below still shows the old name, `foobar.Migrations.CreateDepartments`
> for instance, because it is a record of what actually ran. The database, its user and its volume
> became `company_directory` in the same change. Underscores rather than hyphens, because a
> hyphenated PostgreSQL identifier must be quoted in every statement that names it. See #52.

**Written 2026-08-14**, from working out how to map a unique-constraint violation to a `409`. That
one line of `catch` turned out to need most of this document to justify, which is a good sign it was
worth writing down.

Companion documents: [`POSTGRES.md`](POSTGRES.md) is how this project got onto PostgreSQL, and
[`MIGRATIONS.md`](MIGRATIONS.md) covers schema changes.

## Fluent is not one module

`import Fluent` is a stack, not a library. `fluent/Sources/Fluent/Exports.swift` is one line:

```swift
@_exported import FluentKit
```

Everything you think of as Fluent is `FluentKit`: `Model`, `@Field`, `@ID`, `QueryBuilder`,
`Migration`. The `Fluent` module itself only adds the Vapor integration, meaning `app.db`, the
`migrate` command, `application.migrations`, and the session and authentication helpers.

```
your handler
  Fluent                  Vapor integration: app.db, migrate command, auth/session helpers
    └ FluentKit           the ORM proper: Model, @Field, QueryBuilder, Migration, DatabaseError
  FluentPostgresDriver    the adapter that makes PostgreSQL look like a FluentKit Database
    └ PostgresKit         SQLKit + PostgresNIO glue
        └ PostgresNIO     the wire protocol, and where PSQLError lives
    └ SQLKit              generic SQL builder; FluentSQL translates FluentKit queries into it
```

**FluentKit knows nothing about PostgreSQL.** That is the design, and it is why swapping the driver
in [`POSTGRES.md`](POSTGRES.md) step 2 did not touch a single model or query. The driver package is
an adapter and nothing else.

Because of `@_exported import`, `import Fluent` puts every FluentKit name in scope *and* makes
`FluentKit` usable as a qualifier. An explicit `import FluentKit` adds nothing. I verified that by
deleting it and rebuilding.

## Where a database error comes from

This is the part that makes the rest make sense. When `newDepartment.save(on: database)` hits a
unique-constraint violation:

1. FluentKit builds a `DatabaseQuery`.
2. FluentPostgresDriver, via FluentSQL and SQLKit, turns it into SQL.
3. PostgresNIO sends it. The server replies with an error carrying SQLSTATE `23505`.
4. **PostgresNIO throws `PSQLError`**, a PostgresNIO type.
5. It propagates up through FluentKit **unchanged**. Fluent does not wrap it.

So the error your `catch` receives is not a Fluent error at all. It belongs to a module three layers
down that your code never imports. The naive way to inspect it means importing PostgresNIO into the
handler and knowing SQLSTATE codes, which puts PostgreSQL back into the one place the layering
exists to keep it out of.

## The trick, retroactive conformance

`fluent-postgres-driver/Sources/FluentPostgresDriver/PostgresError+Database.swift`:

```swift
extension PostgresError: @retroactive DatabaseError {}
extension PSQLError:     @retroactive DatabaseError {}
```

Three parts working together:

- **FluentKit declares the vocabulary.** `DatabaseError` is a three-property protocol:
  `isSyntaxError`, `isConstraintFailure`, `isConnectionClosed`.
- **The driver supplies the conformance**, translating SQLSTATE into those booleans.
- **Your code depends only on the vocabulary.**

Which is why this compiles in a file with no PostgreSQL import, and would keep working on MySQL or
SQLite, since each driver ships its own conformance:

```swift
} catch let error as any FluentKit.DatabaseError where error.isConstraintFailure {
```

`@retroactive` is Swift 6 making you acknowledge that you are conforming a type you do not own to a
protocol you do not own. It is fragile by admission. If PostgresNIO ever declared its own
`DatabaseError` conformance, the two would collide.

## Why the `FluentKit.` qualifier

Originally it was mandatory. `Database.swift` declared its own `enum DatabaseError`, and inside the
module an unqualified name resolves to the module's own declaration first. Without the qualifier the
compiler said:

```
error: 'any' has no effect on concrete type 'DatabaseError'
error: value of type 'DatabaseError' has no member 'isConstraintFailure'
```

Worth noticing how *loudly* that failed. `any` is meaningless on a concrete type, so the compiler
stopped. Had the local type been a protocol, this would have compiled and silently never matched,
giving a `catch` clause that looks right and never fires.

That enum has since become `DatabaseSetupError`, which is a better name anyway. It describes startup
failures from `configureDatabase`, not database errors generally. The qualifier is therefore no
longer required.

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
on these tables, so a constraint failure during `createDepartment` can only mean a duplicate name.

**Phase 2 breaks this.** Once `employees.department_id` has a foreign key, a request naming a
department that does not exist raises a `foreignKeyViolation`, which this code would report as
"An employee named X already exists". Wrong, and confusingly so.

At that point the choice is:

| Option | Cost |
| --- | --- |
| Match SQLSTATE `23505` directly | `import PostgresNIO` in the handler; portability lost |
| Inspect the constraint name in the error | Also driver-specific, and depends on Fluent's generated names |
| Look up the department before saving | An extra query, and it races too, but the failure mode is a `404`, which is at least the right answer |

None is free. The comment in `APIHandler` names the hazard so a confused user does not have to
rediscover it.

## Resolved 2026-08-17, both of the last two rather than one

#18 made the foreign key real, so #21 had to be answered. The answer was to take the third option
*and* the first, because they solve different halves of the problem.

**The pre-check is what produces a good response.** `createEmployee` looks the department up before
saving, so the client gets `No department exists with id 999` rather than a constraint failure to
interpret. A pre-check alone would be enough if requests never interleaved.

**SQLSTATE is what covers the race.** The department can be deleted between that lookup and the
insert, and the resulting `foreignKeyViolation` still has to be distinguished from a duplicate name.
`isConstraintFailure` cannot do it, so `ConstraintViolation` reads the SQLSTATE:

```swift
enum ConstraintViolation { case unique, foreignKey, other }
```

```swift
} catch let error where ConstraintViolation(error) == .unique {
```

**The portability cost is real and confined to one file.** `ConstraintViolation.swift` is the only
place in the project that imports `PostgresNIO`, and changing database means rewriting one
initialiser rather than auditing four handlers. That containment is the whole reason it is a type
rather than a condition written inline. When an abstraction cannot answer a question, the honest
move is to go around it in one marked place rather than pretend the question does not arise.

A side effect worth noting: the four `catch` blocks are now *narrower* than they were. Anything that
is neither a unique nor a foreign-key violation, a `NOT NULL` or `CHECK` failure for instance,
propagates and becomes a `500`. That is the correct answer for a constraint nobody anticipated, where
the previous code would have reported a confident and wrong `409`.

## Why `model.id` is optional, and what to do about it

`@ID var id: Int?` is optional for a real reason. The database assigns the value, so between `init`
and a successful `save` there genuinely is no id. The type is honest. What is dishonest is
`model.id!` at the call site, which asserts an invariant nothing states and the compiler cannot
check, namely that Fluent has populated this by now.

FluentKit already ships the answer, at `Model.swift:22`:

```swift
public func requireID() throws -> IDValue {
    guard let id = self.id else { throw FluentError.idRequired }
    return id
}
```

**The difference is not stylistic.** A failed force unwrap is a *trap*, and a trap aborts the
process. In a server that kills every in-flight request on the instance, not just the one holding the
bad model. `requireID()` throws, Vapor's error middleware answers `500`, and the server keeps
serving. Restoring `id!` under the schema-conversion tests demonstrates it directly:

```
foobar/SchemaConversions.swift:22: Fatal error: Unexpectedly found nil while unwrapping an Optional
error: Process ... exited with unexpected signal code 5
```

The test *process* died rather than a test failing.

`Sources/CompanyDirectory/SchemaConversions.swift` is now the single place a model id is unwrapped.
The conversions are initializers on the **schema** type rather than a `toSchema()` method on the
model, so the dependency points from the generated API layer at the domain model and never back.
Regenerating the spec cannot ripple into `Models.swift`.

## The N+1 problem, which Phase 2 walks straight into

An ORM makes the expensive thing look identical to the cheap thing at the call site. That is its main
convenience and its main hazard.

Once `@Parent` exists, this looks harmless:

```swift
let employees = try await Models.Employee.query(on: database).all()
let response = employees.map { employee in
    Components.Schemas.Employee(
        // ...
        departmentName: employee.department.name   // ← a database round trip, per employee
    )
}
```

One query for the employees, then **one more per employee** for their department. Twenty employees,
twenty-one queries. Nothing in the syntax suggests it. `employee.department.name` reads like a
property access, because it is one.

Fluent's answer is eager loading:

```swift
let employees = try await Models.Employee.query(on: database)
    .with(\.$department)
    .all()
```

Two queries total, regardless of row count. `.with(\.$employees)` does the same from the `@Children`
side.

Fluent partly protects you here. Accessing an un-eager-loaded relation **traps** rather than silently
issuing a query, which turns a performance bug into a crash you cannot miss. Do not rely on that as
the whole defence. The `$department.id` shortcut is always available without loading, so the trap
only fires when the full model is touched.

To catch it, count the queries for a single request. Vapor can log SQL, and the number should stay
constant as the result set grows. If query count scales with rows returned, that is N+1 regardless of
how fast it currently feels. This project's tables are small enough that twenty-one queries and two
are indistinguishable by eye.

## Reading the source is the fastest way

I established everything above by reading `.build/checkouts`, not documentation. That directory is
the real reference for this stack:

```bash
grep -rn "isConstraintFailure" .build/checkouts/
sed -n 50,80p .build/checkouts/fluent-postgres-driver/Sources/FluentPostgresDriver/PostgresError+Database.swift
cat .build/checkouts/fluent/Sources/Fluent/Exports.swift
```

Fluent's API documentation is thin on exactly this kind of question: which types cross which
boundary, and what a driver adds to the core. The checkouts answer it in seconds and cannot be out of
date, because they are the version you are compiling against.
