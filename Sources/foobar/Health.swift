import Vapor

struct HealthResponse: Content {
    let status: String
    let timestamp: String
    let uptime: Int
    let environment: String
    let checks: [String: String]
}

func healthRoute(_ application: Application) {
    let startTime = Date()
    // Capture environment as String (Sendable) to avoid accessing non-Sendable Application in async handler
    let environment = application.environment.name
    application.get("health") { _ in
        HealthResponse(
            status: "ok",
            timestamp: Date().formatted(.iso8601),
            uptime: Int(Date().timeIntervalSince(startTime)),
            environment: environment,
            checks: [:]
        )
    }
}
