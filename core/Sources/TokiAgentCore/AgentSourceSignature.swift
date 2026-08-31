import Foundation

struct AgentSourceSignature: Encodable {
    struct Source: Encodable {
        let reader: String
        let records: [String]
    }

    let coveredFrom: Date
    let coveredTo: Date
    let deferredEventRecheck: AgentDeferredEventRecheck.Signature?
    let sources: [Source]
}
