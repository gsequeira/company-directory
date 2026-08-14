import Vapor

/// Registers hand-written routes.
///
/// Routes generated from `openapi.yaml` are registered separately, in `configureServer`.
func routes(_ application: Application) {
    healthRoute(application)
}
