import ServiceLifecycle
import Vapor

@main
struct Entrypoint {
    static func main() async throws {
        let logger = Logger(label: "com.sequeiralabs.company-directory")

        let application = try await Application.make(logger: logger)

        do {
            let serverService = try await configureServer(application)

            // SIGINT drains in-flight requests before exiting; SIGTERM cancels immediately.
            let services: [Service] = [serverService]
            let serviceGroup = ServiceGroup(
                services: services,
                gracefulShutdownSignals: [.sigint],
                cancellationSignals: [.sigterm],
                logger: logger
            )

            try await serviceGroup.run()
        } catch {
            try await application.asyncShutdown()
            logger.error("Application startup failed", metadata: ["error": "\(error)"])
            exit(1)
        }
    }
}
