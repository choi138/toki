import TokiHubCore

@main
enum TokiHubMain {
    static func main() async throws {
        try await TokiHubCommand.run()
    }
}
