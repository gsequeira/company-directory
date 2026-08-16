import Fluent
import OpenAPIVapor
import ServiceLifecycle
import Vapor

/// Configures the database, routes and OpenAPI handlers, then returns the server as a
/// `Service` ready to be run by a `ServiceGroup`.
///
/// The returned service is not started; calling this function has no effect on the network.
///
/// - Parameter databaseConfiguration: Passed through to `configureDatabase(application:)`.
///   Defaults to the environment-derived configuration; the test suite supplies its own.
func configureServer(
    _ application: Application,
    databaseConfiguration: DatabaseConfigurationFactory? = nil
) async throws -> Service {
    try await configureDatabase(application: application, configuration: databaseConfiguration)

    routes(application)

    let handler = APIHandler(database: application.db)

    // Registers every operation declared in openapi.yaml onto the Vapor router.
    let transport = VaporTransport(routesBuilder: application)
    try handler.registerHandlers(
        on: transport,
        serverURL: Servers.Server1.url(),
        configuration: .init()
    )

    return ServerService(application: application)
}

struct ServerService: Service {
    let application: Application

    func run() async throws {
        try await application.execute()
    }
}
