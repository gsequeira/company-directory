import Vapor
import ServiceLifecycle
import OpenAPIVapor

func configureServer(_ application: Application) async throws -> Service {
    routes(application)

    // Create API handler for request processing
    let handler = APIHandler()

    // Register OpenAPI-generated handlers with Vapor transport
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
