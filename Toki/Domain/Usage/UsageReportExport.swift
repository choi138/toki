import Foundation

enum UsageExportFormat: String, CaseIterable {
    case csv = "CSV"
    case json = "JSON"
}

private let usageExportISODateFormatter = ISO8601DateFormatter()

enum UsageExport {
    static func string(for usage: UsageData, format: UsageExportFormat) -> String {
        switch format {
        case .csv:
            csvString(for: usage)
        case .json:
            jsonString(for: usage)
        }
    }

    static func csvString(for usage: UsageData) -> String {
        let rows = csvRows(for: usage)
        return rows.map { row in
            row.map(csvEscape).joined(separator: ",")
        }
        .joined(separator: "\n")
    }

    static func jsonString(for usage: UsageData) -> String {
        let payload = UsageExportPayload(usage: usage)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

private struct UsageExportPayload: Encodable {
    let date: String
    let startDate: String
    let endDate: String
    let totals: UsageExportTotals
    let sources: [UsageExportSource]
    let models: [UsageExportModel]
    let projects: [UsageExportProject]
    let sessions: [UsageExportSession]

    init(usage: UsageData) {
        date = usageExportISODateFormatter.string(from: usage.date)
        startDate = usageExportISODateFormatter.string(from: usage.date)
        endDate = usageExportISODateFormatter.string(from: usage.endDate)
        totals = UsageExportTotals(usage: usage)
        sources = usage.sourceStats.map(UsageExportSource.init)
        models = usage.perModel.map(UsageExportModel.init)
        projects = usage.projectStats.map(UsageExportProject.init)
        sessions = usage.sessionStats.map(UsageExportSession.init)
    }
}

private struct UsageExportTotals: Encodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let cost: Double
    let activeSeconds: TimeInterval

    init(usage: UsageData) {
        inputTokens = usage.inputTokens
        outputTokens = usage.outputTokens
        cacheReadTokens = usage.cacheReadTokens
        cacheWriteTokens = usage.cacheWriteTokens
        reasoningTokens = usage.reasoningTokens
        totalTokens = usage.totalTokens
        cost = usage.cost
        activeSeconds = usage.activeSeconds
    }
}

private struct UsageExportSource: Encodable {
    let source: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let cost: Double
    let activeSeconds: TimeInterval

    init(source: SourceStat) {
        self.source = source.source
        inputTokens = source.inputTokens
        outputTokens = source.outputTokens
        cacheReadTokens = source.cacheReadTokens
        cacheWriteTokens = source.cacheWriteTokens
        reasoningTokens = source.reasoningTokens
        totalTokens = source.totalTokens
        cost = source.cost
        activeSeconds = source.activeSeconds
    }
}

private struct UsageExportModel: Encodable {
    let model: String
    let totalTokens: Int
    let cost: Double
    let activeSeconds: TimeInterval
    let sources: [String]
    let isPriceKnown: Bool

    init(model: ModelStat) {
        self.model = model.id
        totalTokens = model.totalTokens
        cost = model.cost
        activeSeconds = model.activeSeconds
        sources = model.sources
        isPriceKnown = model.isPriceKnown
    }
}

private struct UsageExportProject: Encodable {
    let name: String
    let path: String?
    let quality: String
    let sources: [String]
    let sessionCount: Int
    let totalTokens: Int
    let cost: Double
    let firstActivityAt: String?
    let lastActivityAt: String?

    init(project: ProjectUsageStat) {
        name = project.name
        path = project.path
        quality = project.quality.rawValue
        sources = project.sources
        sessionCount = project.sessionCount
        totalTokens = project.totalTokens
        cost = project.cost
        firstActivityAt = project.firstActivityAt.map { usageExportISODateFormatter.string(from: $0) }
        lastActivityAt = project.lastActivityAt.map { usageExportISODateFormatter.string(from: $0) }
    }
}

private struct UsageExportSession: Encodable {
    let source: String
    let projectName: String
    let projectPath: String?
    let sessionID: String?
    let sessionLabel: String
    let quality: String
    let models: [String]
    let totalTokens: Int
    let cost: Double
    let firstActivityAt: String
    let lastActivityAt: String

    init(session: SessionUsageStat) {
        source = session.source
        projectName = session.projectName
        projectPath = session.projectPath
        sessionID = session.sessionID
        sessionLabel = session.sessionLabel
        quality = session.quality.rawValue
        models = session.models
        totalTokens = session.totalTokens
        cost = session.cost
        firstActivityAt = usageExportISODateFormatter.string(from: session.firstActivityAt)
        lastActivityAt = usageExportISODateFormatter.string(from: session.lastActivityAt)
    }
}

private extension UsageExport {
    static func csvRows(for usage: UsageData) -> [[String]] {
        let startDate = usageExportISODateFormatter.string(from: usage.date)
        let endDate = usageExportISODateFormatter.string(from: usage.endDate)

        return [csvHeader, csvTotalRow(for: usage, startDate: startDate, endDate: endDate)]
            + csvSourceRows(for: usage, startDate: startDate, endDate: endDate)
            + csvModelRows(for: usage, startDate: startDate, endDate: endDate)
            + csvProjectRows(for: usage)
            + csvSessionRows(for: usage)
    }

    static var csvHeader: [String] {
        [
            "section",
            "name",
            "source",
            "model",
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
            "reasoning_tokens",
            "total_tokens",
            "cost_usd",
            "active_seconds",
            "start_date",
            "end_date",
            "project_path",
            "session_id",
            "attribution_quality",
        ]
    }

    static func csvTotalRow(
        for usage: UsageData,
        startDate: String,
        endDate: String) -> [String] {
        [
            "total",
            "All",
            "",
            "",
            "\(usage.inputTokens)",
            "\(usage.outputTokens)",
            "\(usage.cacheReadTokens)",
            "\(usage.cacheWriteTokens)",
            "\(usage.reasoningTokens)",
            "\(usage.totalTokens)",
            String(format: "%.6f", usage.cost),
            String(format: "%.3f", usage.activeSeconds),
            startDate,
            endDate,
            "",
            "",
            "",
        ]
    }

    static func csvSourceRows(
        for usage: UsageData,
        startDate: String,
        endDate: String) -> [[String]] {
        usage.sourceStats.map { source in
            [
                "source",
                source.source,
                source.source,
                "",
                "\(source.inputTokens)",
                "\(source.outputTokens)",
                "\(source.cacheReadTokens)",
                "\(source.cacheWriteTokens)",
                "\(source.reasoningTokens)",
                "\(source.totalTokens)",
                String(format: "%.6f", source.cost),
                String(format: "%.3f", source.activeSeconds),
                startDate,
                endDate,
                "",
                "",
                "",
            ]
        }
    }

    static func csvModelRows(
        for usage: UsageData,
        startDate: String,
        endDate: String) -> [[String]] {
        usage.perModel.map { model in
            [
                "model",
                model.id,
                model.sources.joined(separator: ";"),
                model.id,
                "",
                "",
                "",
                "",
                "",
                "\(model.totalTokens)",
                model.isPriceKnown ? String(format: "%.6f", model.cost) : "",
                String(format: "%.3f", model.activeSeconds),
                startDate,
                endDate,
                "",
                "",
                "",
            ]
        }
    }

    static func csvProjectRows(for usage: UsageData) -> [[String]] {
        usage.projectStats.map { project in
            [
                "project",
                project.name,
                project.sources.joined(separator: ";"),
                "",
                "\(project.inputTokens)",
                "\(project.outputTokens)",
                "\(project.cacheReadTokens)",
                "\(project.cacheWriteTokens)",
                "\(project.reasoningTokens)",
                "\(project.totalTokens)",
                String(format: "%.6f", project.cost),
                "",
                project.firstActivityAt.map { usageExportISODateFormatter.string(from: $0) } ?? "",
                project.lastActivityAt.map { usageExportISODateFormatter.string(from: $0) } ?? "",
                project.path ?? "",
                "",
                project.quality.rawValue,
            ]
        }
    }

    static func csvSessionRows(for usage: UsageData) -> [[String]] {
        usage.sessionStats.map { session in
            [
                "session",
                session.projectName,
                session.source,
                session.models.joined(separator: ";"),
                "\(session.inputTokens)",
                "\(session.outputTokens)",
                "\(session.cacheReadTokens)",
                "\(session.cacheWriteTokens)",
                "\(session.reasoningTokens)",
                "\(session.totalTokens)",
                String(format: "%.6f", session.cost),
                "",
                usageExportISODateFormatter.string(from: session.firstActivityAt),
                usageExportISODateFormatter.string(from: session.lastActivityAt),
                session.projectPath ?? "",
                session.sessionID ?? "",
                session.quality.rawValue,
            ]
        }
    }

    static func csvEscape(_ value: String) -> String {
        guard value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r") else {
            return value
        }

        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
