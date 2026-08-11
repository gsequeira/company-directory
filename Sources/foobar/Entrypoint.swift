import Vapor
import ServiceLifecycle
@main
struct Entrypoint {
    static func main() async throws {
        // Create a Logger
        let logger = Logger(label: "com.sequeiralabs.foobar")

        // Create the Vapor application instance
        let application = try await Application.make(logger: logger)

        do {
        // Configure the server and create the service wrapper
        let serverService =  try await configureServer(application)

        // Create service group with graceful shutdown handling
        let services: [Service] = [serverService]
        let serviceGroup = ServiceGroup(
            services: services,
            gracefulShutdownSignals: [.sigint],
            cancellationSignals: [.sigterm],
            logger: logger
        )

        // Start the service group and run until shutdown
        try await serviceGroup.run()
        } catch {
            try await application.asyncShutdown()
            logger.error("Application startup failed", metadata: ["error": "\(error)"])
            exit(1)
        }
    }
}
