# Middleware

Why this project needs middleware, how it wires in alongside the generated OpenAPI routes, and what
is planned. Structured so further middleware can be added as they become worth having.

**Written 2026-08-16**, because two open issues both resolve to "write a middleware" — #24
(authentication) and #2 (malformed input returns `500` instead of `400`) — and neither had anywhere
to explain why that is the right layer.

Companion documents: [`API-DESIGN.md`](API-DESIGN.md) is what the API should contain,
[`API-COVERAGE.md`](API-COVERAGE.md) audits what is tested, and [`FLUENT.md`](FLUENT.md) covers the
layer below the handlers.

## What a middleware is here

A middleware sits between the server and the router, and can read or alter the request on the way
in, the response on the way out, or answer immediately without the router ever running.

```swift
public protocol Middleware: Sendable {
    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response>
}

public protocol AsyncMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response
}
```

Write `AsyncMiddleware` — everything else in this codebase is `async`, and Vapor's own bundled
middleware conform to it.

The `chainingTo next` parameter is what makes it a chain rather than a hook: calling `next` passes
control inward, and *not* calling it short-circuits the request.

## Why this API needs them at all

The generated `APIProtocol` gives one function per operation. Anything that must apply to **every**
operation, or must happen **before** one runs, has nowhere to live in that model — putting it in ten
handlers means ten chances to forget it, and it would not run at all for a request that never
reaches a handler.

That is precisely the shape of both open issues: rejecting an unauthenticated request before it
touches the database, and turning a decoding failure into the right status when there is no handler
to return one.

## What is registered today

**Nothing by this project.** Vapor installs two by default, in this order:

| Middleware | Effect |
| --- | --- |
| `RouteLoggingMiddleware(logLevel: .info)` | Logs the matched route |
| `ErrorMiddleware.default(environment:)` | Turns a thrown error into a response |

The second is why a thrown error becomes a `500` rather than a dropped connection — and, as *Planned
— error mapping* below explains, why it becomes a `500` rather than a `400`.

## The two registration points, and why the difference matters

```swift
application.middleware.use(SomeMiddleware())            // everything, including /health
```

```swift
let protected = application.grouped(SomeMiddleware())   // only what is built on this
let transport = VaporTransport(routesBuilder: protected)
```

`VaporTransport.init` takes `any Vapor.RoutesBuilder`, and `RoutesBuilder.grouped(_:)` returns
another one — so substituting the second form in `configureServer` puts every generated operation
behind the middleware, and nothing else.

**That distinction is already load-bearing.** `/health` is registered by `routes(application)`
directly on the application, outside any group. Protecting the API by grouping the transport leaves
health probes reachable without a single line of exemption logic. The separation exists for
unrelated reasons and happens to be exactly right.

## Order is significant, and the direction is worth memorising

From `Middleware.swift`:

```swift
for middleware in reversed() {
    responder = middleware.makeResponder(chainingTo: responder)
}
```

The array is wrapped from the back, so **the first middleware registered is the outermost** — first
to see the request, last to see the response. Anything that must observe errors thrown by another
middleware has to be registered *before* it.

## Planned — authentication (#24)

Design and constraints live on #24; the mechanism is a one-line substitution in `configureServer`:

```swift
let transport = VaporTransport(routesBuilder: application.grouped(APIKeyMiddleware()))
```

Three things the middleware itself has to get right:

- **Compare the credential in constant time.** `==` on strings short-circuits, leaking length and
  prefix through timing.
- **Read the credential from the environment and fail startup if it is absent.** A default token is
  worse than no authentication, because the API looks protected.
- **Throw `Abort(.unauthorized)`**, so the error middleware maps it correctly.

### The caveat that applies to every middleware here

**A middleware rejects before the generated handler runs, so its response body is Vapor's, not one
`openapi.yaml` describes.** A `401` will be `{"error":true,"reason":"Unauthorized"}` regardless of
what the spec declares.

This is the one place in the project where the spec is not the source of truth, and it is a property
of the layer rather than a bug. Worth stating in the spec rather than leaving to be discovered.

**Note also that `swift-openapi-generator` supports neither `security` nor `securitySchemes`** —
both unchecked in its feature matrix. Declaring them generates and enforces nothing. The declaration
is documentation for humans and other tooling; the middleware is what enforces.

## Planned — error mapping (#2)

Malformed input returns `500` on every endpoint. The cause is visible in
`ErrorMiddleware.default(environment:)`:

```swift
case let abort as AbortError:          // uses abort.status
case let debugErr as DebuggableError:  // 500
default:                               // 500
    reason = environment.isRelease ? "Something went wrong." : String(describing: error)
```

`swift-openapi-vapor` surfaces a request-decoding failure as an ordinary error, not an `AbortError`,
so it falls to `default` and becomes a `500` — a status declared nowhere in the spec, breaking the
contract on all ten operations.

Two consequences worth separating. The status is wrong, which is #2. And outside a release build the
body carries `String(describing: error)`, so a client-side typo is answered with the internals of a
decoding error — a `922`-byte response, observed.

The fix is a middleware registered **outside** the error middleware, recognising the decoding
failure and rethrowing it as `Abort(.badRequest)`. The error type cannot be made to conform to
`AbortError` from here; it belongs to a dependency.

#14 is the acceptance criteria: those tests are written now inside `withKnownIssue`, assert the
`400` that should be returned, and fail the moment this middleware makes them pass. See
[`TESTING.md`](TESTING.md) → *Step 7*.

## Candidates, and the condition that would justify each

None of these are needed today. The point of listing them is that the condition is written down, so
adding one is a decision rather than a habit.

| Middleware | Bundled with Vapor | Add it when |
| --- | --- | --- |
| `CORSMiddleware` | Yes | A browser client exists. Not before — it is a header policy for browsers and does nothing for server-to-server callers |
| `ResponseCompressionMiddleware` | Yes | Responses grow past a few KB. List endpoints will get there once pagination (#22) exists and page sizes are real |
| `TracingMiddleware` | Yes | There is more than one service to correlate across. A single process has logs |
| `FileMiddleware` | Yes | Static assets need serving. An API has none |
| Request ID / correlation | No | Logs from concurrent requests become hard to separate. Cheap to add, and the value appears exactly when debugging gets hard |
| Rate limiting | No | The API is exposed to callers you do not control. Needs shared state, so it stops being a one-file middleware the moment there is more than one instance |

**When *not* to reach for a middleware:** anything that needs to know *which* operation it is
handling. A middleware sees a raw `Request` — method, path, headers, bytes — and not the decoded,
typed input the generated handler receives. Re-deriving the operation from the path inside a
middleware duplicates the router and drifts from the spec. That work belongs in the handler, where
the type system already knows the answer.

## Testing them

Through the API, like everything else — `TestHelpers.withApplication` builds a real application, so
a middleware registered in `configureServer` is exercised by every request the suite sends.

That single construction point is also what keeps authentication cheap to introduce later: supplying
a credential is one edit in one place rather than one per test.
