import Vapor

package enum TokiHubCommand {
    package static func run() async throws {
        var environment = try Environment.detect()
        try LoggingSystem.bootstrap(from: &environment)
        let application = try await Application.make(environment)

        do {
            let configuration = try HubConfiguration()
            try configureHub(application, configuration: configuration)
            try await application.execute()
            try await application.asyncShutdown()
        } catch {
            try? await application.asyncShutdown()
            throw error
        }
    }
}
