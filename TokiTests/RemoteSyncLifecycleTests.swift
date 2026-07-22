import XCTest
@testable import Toki

final class RemoteSyncLifecycleTests: XCTestCase {
    func test_oldReadTicketCannotCommitAfterMutation() throws {
        let coordinator = RemoteSyncLifecycleCoordinator()
        let ticket = coordinator.beginRead()
        var didCommit = false

        try coordinator.mutate {}

        XCTAssertThrowsError(try coordinator.commit(ticket) {
            didCommit = true
        }) { error in
            guard let lifecycleError = error as? RemoteSyncLifecycleError,
                  case .stateChanged = lifecycleError else {
                return XCTFail("Expected stateChanged, got \(error)")
            }
        }
        XCTAssertFalse(didCommit)
    }
}
