import Foundation
import Testing

@testable import foobar

#if canImport(FoundationNetworking)
    // URLSession lives in a separate module on Linux. The suite is skipped there in practice,
    // but it still has to compile — CI builds every test target on Linux.
    import FoundationNetworking
#endif

// Smoke tests against a *running* server, over a real socket.
//
// This is not a second copy of `APIHandlerIntegrationTests`. That suite drives the application
// in-process through `application.sendRequest` and reverts its migrations after every test, so it
// never binds a port, never reaches `/health`, and never exercises a migration against a database
// that already holds rows. This one does all three.
//
// It runs only when `SMOKE_BASE_URL` is set, so an ordinary `swift test` — and CI, where no server
// is listening — skips it rather than failing:
//
//     swift run foobar serve &
//     SMOKE_BASE_URL=http://127.0.0.1:8080 swift test --filter SmokeTests
//
// `Scripts/smoke.sh` covers the same ground without a build step, and works against a deployment
// from a machine that has no copy of this repository. What this version adds is the generated
// types: responses are decoded into `Components.Schemas.*`, so a change to `openapi.yaml` that
// breaks the contract stops this file compiling rather than failing at run time.
@Suite(
    "Smoke tests",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["SMOKE_BASE_URL"] != nil,
        "set SMOKE_BASE_URL to a running server to enable"
    )
)
struct SmokeTests {

    // MARK: - Transport

    private static var baseURL: String {
        ProcessInfo.processInfo.environment["SMOKE_BASE_URL"] ?? "http://127.0.0.1:8080"
    }

    /// Sends a request and returns the status and body. Deliberately thin: the point is to exercise
    /// the real HTTP stack, so nothing here shares code with the in-process test helpers.
    private func send(
        _ method: String,
        _ path: String,
        json: Data? = nil
    ) async throws -> (status: Int, body: Data) {
        // Not `URL(string:)!`. A malformed SMOKE_BASE_URL is a configuration mistake, and trapping
        // on it would abort the whole test process rather than failing this one test — the same
        // argument as #8. `NeverForceUnwrap` catches this now that #6 enabled it.
        let url = try #require(
            URL(string: Self.baseURL + path),
            "SMOKE_BASE_URL does not form a valid URL: \(Self.baseURL + path)"
        )
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, data)
    }

    private func encode(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// Unique per run, so the suite is safe against a database that already has data.
    ///
    /// Each test deletes what it created as its last step. `#expect` records and continues, so that
    /// cleanup is still reached when an assertion fails; a `try #require` failure throws and skips
    /// it, which is why the names are unique rather than fixed.
    private var runSuffix: String { "smoke-\(ProcessInfo.processInfo.processIdentifier)" }

    // MARK: - The server itself

    @Test("The server is listening and /health answers")
    func testHealth() async throws {
        let (status, body) = try await send("GET", "/health")

        #expect(status == 200)

        // Not a generated type: /health is hand-written and outside the OpenAPI transport, which
        // is exactly why no other test covers it.
        let health = try decode(HealthResponse.self, from: body)
        #expect(health.status == "ok")
    }

    // MARK: - Departments

    @Test("A department round trip, decoded into the generated types")
    func testDepartmentRoundTrip() async throws {
        let name = "\(runSuffix)-dept"

        let created = try await send(
            "POST", "/api/departments",
            json: try encode(Components.Schemas.CreateDepartmentRequest(name: name))
        )
        try #require(created.status == 201)

        // Decoding into the generated type is what this version buys over the shell script: if the
        // spec gains a required field, this stops compiling instead of silently passing.
        let department = try decode(Components.Schemas.Department.self, from: created.body)
        #expect(department.name == name)
        #expect(department.id > 0)

        let fetched = try await send("GET", "/api/departments/\(department.id)")
        #expect(fetched.status == 200)
        let readBack = try decode(Components.Schemas.Department.self, from: fetched.body)
        #expect(readBack == department)

        let duplicate = try await send(
            "POST", "/api/departments",
            json: try encode(Components.Schemas.CreateDepartmentRequest(name: name))
        )
        #expect(duplicate.status == 409)
        let conflict = try decode(Components.Schemas.ConflictError.self, from: duplicate.body)
        #expect(conflict.error == true)
        #expect(conflict.reason.contains(name))

        let deleted = try await send("DELETE", "/api/departments/\(department.id)")
        #expect(deleted.status == 204)

        let gone = try await send("GET", "/api/departments/\(department.id)")
        #expect(gone.status == 404)
        #expect(gone.body.isEmpty)
    }

    // MARK: - Employees

    @Test("A partial patch preserves the field it does not mention")
    func testEmployeePartialUpdate() async throws {
        let lastName = "\(runSuffix)-emp"

        let created = try await send(
            "POST", "/api/employees",
            json: try encode(
                Components.Schemas.CreateEmployeeRequest(firstName: "Ada", lastName: lastName))
        )
        try #require(created.status == 201)
        let employee = try decode(Components.Schemas.Employee.self, from: created.body)

        let patched = try await send(
            "PATCH", "/api/employees/\(employee.id)",
            json: try encode(Components.Schemas.UpdateEmployeeRequest(firstName: "Augusta"))
        )
        #expect(patched.status == 200)

        let updated = try decode(Components.Schemas.Employee.self, from: patched.body)
        #expect(updated.firstName == "Augusta")
        #expect(updated.lastName == lastName)

        let deleted = try await send("DELETE", "/api/employees/\(employee.id)")
        #expect(deleted.status == 204)
    }

    @Test("Unknown ids are not found, with an empty body")
    func testNotFound() async throws {
        for path in ["/api/departments/999999", "/api/employees/999999"] {
            let (status, body) = try await send("GET", path)
            #expect(status == 404, "\(path)")
            // An empty body is what distinguishes a handler 404 from a routing one.
            #expect(body.isEmpty, "\(path)")
        }
    }
}
