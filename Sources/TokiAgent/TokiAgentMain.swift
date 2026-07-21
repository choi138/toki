import TokiAgentCore

@main
enum TokiAgentMain {
    static func main() async {
        await TokiAgentCommand.run()
    }
}
