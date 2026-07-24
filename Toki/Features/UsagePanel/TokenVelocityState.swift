import Foundation

@MainActor
final class TokenVelocityState: ObservableObject {
    @Published private(set) var sample = TokenVelocitySample.zero()

    var liveTokensPerSecond: Double {
        sample.tokensPerSecond
    }

    func update(_ sample: TokenVelocitySample) {
        self.sample = sample
    }
}
