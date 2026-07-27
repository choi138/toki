import XCTest
@testable import Toki

final class MenuBarStatusItemAnimationTests: XCTestCase {
    func test_stoppedAnimationRejectsQueuedFrame() {
        var lifecycle = RabbitRunAnimationLifecycle()
        let queuedGeneration = lifecycle.start()

        lifecycle.stop()

        XCTAssertFalse(lifecycle.shouldApplyFrame(for: queuedGeneration))
    }
}
