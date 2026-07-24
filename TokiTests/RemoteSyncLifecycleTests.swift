import XCTest
@testable import Toki

final class RemoteSyncLifecycleTests: XCTestCase {
    func test_oldReadTicketIsRejectedAfterStateChange() throws {
        let coordinator = RemoteSyncLifecycleCoordinator()
        let ticket = coordinator.beginRead()

        coordinator.invalidateReadTickets()

        XCTAssertThrowsError(try coordinator.validate(ticket)) { error in
            guard let lifecycleError = error as? RemoteSyncLifecycleError,
                  case .stateChanged = lifecycleError else {
                return XCTFail("Expected stateChanged, got \(error)")
            }
        }
    }

    func test_callerCanReenterLifecycleAfterInvalidatingReadTickets() throws {
        let coordinator = RemoteSyncLifecycleCoordinator()

        coordinator.invalidateReadTickets()
        let ticket = coordinator.beginRead()

        XCTAssertNoThrow(try coordinator.validate(ticket))
    }
}
