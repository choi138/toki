import Foundation

struct AgentSourceSignature: Encodable {
    struct Source: Encodable {
        let reader: String
        let records: [String]
        /// Local collection/parser revision. Omitted for unchanged collectors; not a wire field.
        let collectorRevision: Int?
    }

    let coveredFrom: Date
    let coveredTo: Date
    let deferredEventRecheck: AgentDeferredEventRecheck.Signature?
    let sources: [Source]
}
