import Foundation

struct RemoteSnapshotAnchor: Codable, Equatable {
    let sequence: UInt64
    let envelopeDigest: String
}
