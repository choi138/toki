import Foundation

enum UsageExportFormat: String, CaseIterable {
    case csv = "CSV"
    case json = "JSON"
}

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
    let totals: UsageExportTotals
    let sources: [UsageExportSource]
    let models: [UsageExportModel]

    init(usage: UsageData) {
        date = Self.isoDateFormatter.string(from: usage.date)
        totals = UsageExportTotals(usage: usage)
        sources = usage.sourceStats.map(UsageExportSource.init)
        models = usage.perModel.map(UsageExportModel.init)
    }

    private static let isoDateFormatter = ISO8601DateFormatter()
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

private extension UsageExport {
    static func csvRows(for usage: UsageData) -> [[String]] {
        let header = [
            "section",
            "name",
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
            "reasoning_tokens",
            "total_tokens",
            "cost_usd",
            "active_seconds",
        ]

        let total = [
            "total",
            "All",
            "\(usage.inputTokens)",
            "\(usage.outputTokens)",
            "\(usage.cacheReadTokens)",
            "\(usage.cacheWriteTokens)",
            "\(usage.reasoningTokens)",
            "\(usage.totalTokens)",
            String(format: "%.6f", usage.cost),
            String(format: "%.3f", usage.activeSeconds),
        ]

        let sources = usage.sourceStats.map { source in
            [
                "source",
                source.source,
                "\(source.inputTokens)",
                "\(source.outputTokens)",
                "\(source.cacheReadTokens)",
                "\(source.cacheWriteTokens)",
                "\(source.reasoningTokens)",
                "\(source.totalTokens)",
                String(format: "%.6f", source.cost),
                String(format: "%.3f", source.activeSeconds),
            ]
        }

        let models = usage.perModel.map { model in
            [
                "model",
                model.id,
                "",
                "",
                "",
                "",
                "",
                "\(model.totalTokens)",
                model.isPriceKnown ? String(format: "%.6f", model.cost) : "",
                String(format: "%.3f", model.activeSeconds),
            ]
        }

        return [header, total] + sources + models
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
