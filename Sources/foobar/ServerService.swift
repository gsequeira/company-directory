import Vapor
import ServiceLifecycle

func configureServer(_ application: Application) async throws -> Service {
    routes(application)
    return ServerService(application: application)
}

struct ServerService: Service {
    let application: Application

    func run() async throws {
        try await application.execute()
    }
}
