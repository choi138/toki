import Foundation
import XCTest
@testable import Toki

final class LaunchAtLoginViewModelTests: XCTestCase {
    @MainActor
    func testInitialStateAndReloadReflectServiceStatus() {
        let service = LaunchAtLoginServiceStub(isEnabled: true)
        let viewModel = LaunchAtLoginViewModel(service: service)

        XCTAssertTrue(viewModel.isEnabled)

        service.setCurrentStatus(false)
        viewModel.reload()

        XCTAssertFalse(viewModel.isEnabled)
    }

    @MainActor
    func testSetEnabledPublishesSuccessfulServiceState() async {
        let service = LaunchAtLoginServiceStub(isEnabled: false)
        let viewModel = LaunchAtLoginViewModel(service: service)

        viewModel.setEnabled(true)

        XCTAssertTrue(viewModel.isUpdating)
        XCTAssertNil(viewModel.errorMessage)
        await waitForUpdate(viewModel)
        XCTAssertTrue(viewModel.isEnabled)
        XCTAssertEqual(service.setEnabledCallCount, 1)
    }

    @MainActor
    func testSetEnabledReportsFailureAndRestoresServiceState() async {
        let service = LaunchAtLoginServiceStub(
            isEnabled: false,
            error: LaunchAtLoginServiceStubError.registrationFailed)
        let viewModel = LaunchAtLoginViewModel(service: service)

        viewModel.setEnabled(true)
        await waitForUpdate(viewModel)

        XCTAssertFalse(viewModel.isEnabled)
        XCTAssertEqual(viewModel.errorMessage, "Registration failed")
        XCTAssertEqual(service.setEnabledCallCount, 1)
    }

    @MainActor
    func testSetEnabledIgnoresCurrentValue() async {
        let service = LaunchAtLoginServiceStub(isEnabled: true)
        let viewModel = LaunchAtLoginViewModel(service: service)

        viewModel.setEnabled(true)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(viewModel.isUpdating)
        XCTAssertEqual(service.setEnabledCallCount, 0)
    }
}

private extension LaunchAtLoginViewModelTests {
    @MainActor
    func waitForUpdate(_ viewModel: LaunchAtLoginViewModel) async {
        for _ in 0..<50 {
            guard viewModel.isUpdating else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Launch at Login update did not finish")
    }
}

private enum LaunchAtLoginServiceStubError: LocalizedError {
    case registrationFailed

    var errorDescription: String? {
        "Registration failed"
    }
}

private final class LaunchAtLoginServiceStub: LaunchAtLoginServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedIsEnabled: Bool
    private var storedSetEnabledCallCount = 0
    private let error: Error?

    init(isEnabled: Bool, error: Error? = nil) {
        storedIsEnabled = isEnabled
        self.error = error
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedIsEnabled
    }

    var setEnabledCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSetEnabledCallCount
    }

    func setEnabled(_ isEnabled: Bool) throws {
        lock.lock()
        storedSetEnabledCallCount += 1
        let error = error
        if error == nil {
            storedIsEnabled = isEnabled
        }
        lock.unlock()

        if let error {
            throw error
        }
    }

    func setCurrentStatus(_ isEnabled: Bool) {
        lock.lock()
        storedIsEnabled = isEnabled
        lock.unlock()
    }
}
