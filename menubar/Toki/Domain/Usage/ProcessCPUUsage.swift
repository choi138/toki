import Foundation

struct ProcessCPUUsageSample: Equatable {
    let userSeconds: TimeInterval
    let systemSeconds: TimeInterval
    let uptimeSeconds: TimeInterval

    var isValid: Bool {
        userSeconds.isFinite && userSeconds >= 0
            && systemSeconds.isFinite && systemSeconds >= 0
            && uptimeSeconds.isFinite && uptimeSeconds >= 0
    }
}

struct ProcessCPUUsageCalculator {
    private var baseline: ProcessCPUUsageSample?

    mutating func reset() {
        baseline = nil
    }

    mutating func percentage(for sample: ProcessCPUUsageSample?) -> Double? {
        guard let sample, sample.isValid else {
            reset()
            return nil
        }
        guard let previous = baseline else {
            baseline = sample
            return nil
        }
        let elapsed = sample.uptimeSeconds - previous.uptimeSeconds
        let userDelta = sample.userSeconds - previous.userSeconds
        let systemDelta = sample.systemSeconds - previous.systemSeconds
        guard elapsed > 0, userDelta >= 0, systemDelta >= 0 else {
            reset()
            return nil
        }
        // Activity Monitor convention: one fully occupied logical core is 100%.
        let percentage = (userDelta + systemDelta) / elapsed * 100
        guard percentage.isFinite else {
            reset()
            return nil
        }
        baseline = sample
        return percentage
    }
}
