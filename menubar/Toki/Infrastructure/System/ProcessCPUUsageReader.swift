import Darwin
import Foundation

enum ProcessCPUUsageReader {
    static func sample() -> ProcessCPUUsageSample? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return ProcessCPUUsageSample(
            userSeconds: seconds(usage.ru_utime),
            systemSeconds: seconds(usage.ru_stime),
            uptimeSeconds: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000)
    }

    private static func seconds(_ time: timeval) -> TimeInterval {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
}
