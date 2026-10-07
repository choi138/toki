import Foundation

func piFamilyDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value) ?? .distantPast
}

func piFamilyMessage(
    id: String,
    timestamp: String = "2026-08-20T12:00:00Z",
    model: String = "gpt-5.6-sol",
    provider: String = "openai",
    input: Int,
    output: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0,
    reasoning: Int? = nil) -> String {
    var usage = [
        #""input":\#(input)"#,
        #""output":\#(output)"#,
        #""cacheRead":\#(cacheRead)"#,
        #""cacheWrite":\#(cacheWrite)"#,
    ]
    if let reasoning {
        usage.append(#""reasoning":\#(reasoning)"#)
    }
    return """
    {"type":"message","id":"\(id)","timestamp":"\(timestamp)","message":\
    {"role":"assistant","model":"\(model)","provider":"\(provider)",\
    "usage":{\(usage.joined(separator: ","))}}}
    """
}

func writePiFamilySession(
    to url: URL,
    sessionID: String,
    messageID: String,
    input: Int,
    output: Int,
    cwd: String? = "/tmp/project") throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    var sessionFields = [#""type":"session""#, #""id":"\#(sessionID)""#]
    if let cwd {
        sessionFields.append(#""cwd":"\#(cwd)""#)
    }
    let content = [
        "{\(sessionFields.joined(separator: ","))}",
        piFamilyMessage(id: messageID, input: input, output: output),
    ].joined(separator: "\n")
    try Data(content.utf8).write(to: url)
}

func writePiFamilyIdlessSession(
    to url: URL,
    sessionID: String,
    responseID: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    let content = [
        #"{"type":"session","id":"\#(sessionID)","cwd":"/tmp/project"}"#,
        """
        {"type":"message","timestamp":"2026-08-20T12:00:00Z","message":\
        {"role":"assistant","model":"gpt-5.6-sol","provider":"openai",\
        "responseId":"\(responseID)","usage":{"input":3,"output":2}}}
        """,
    ].joined(separator: "\n")
    try Data(content.utf8).write(to: url)
}

func writePiFamilySessionHeader(to url: URL, sessionID: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(#"{"type":"session","id":"\#(sessionID)"}"#.utf8).write(to: url)
}
