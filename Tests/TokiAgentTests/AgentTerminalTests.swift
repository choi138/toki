import Foundation
import XCTest
@testable import TokiAgentCore

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

final class AgentTerminalTests: XCTestCase {
    func test_interactiveCanonicalTerminalLineDoesNotReadForEOF() throws {
        let line = Data("pairing-bundle\n".utf8)
        var readCount = 0

        let data = try TokiAgentCommand.readPairingBundle(isTerminal: true) { _ in
            readCount += 1
            return readCount == 1 ? line : nil
        }

        XCTAssertEqual(data, line)
        XCTAssertEqual(readCount, 1)
    }

    func test_pairingInputDisablesTerminalEchoAndRestoresItAfterFailure() throws {
        let terminal = try PseudoTerminal()
        defer { terminal.close() }
        var original = termios()
        XCTAssertEqual(tcgetattr(terminal.terminalDescriptor, &original), 0)
        original.c_lflag |= tcflag_t(ECHO)
        XCTAssertEqual(tcsetattr(terminal.terminalDescriptor, TCSANOW, &original), 0)

        XCTAssertThrowsError(try AgentTerminal.withEchoDisabledIfNeeded(
            fileDescriptor: terminal.terminalDescriptor) {
                var hidden = termios()
                XCTAssertEqual(tcgetattr(terminal.terminalDescriptor, &hidden), 0)
                XCTAssertEqual(hidden.c_lflag & tcflag_t(ECHO), 0)
                throw TerminalTestError.expected
            }) { error in
                XCTAssertTrue(error is TerminalTestError)
            }

        var restored = termios()
        XCTAssertEqual(tcgetattr(terminal.terminalDescriptor, &restored), 0)
        XCTAssertNotEqual(restored.c_lflag & tcflag_t(ECHO), 0)
    }
}

private final class PseudoTerminal {
    let controllerDescriptor: Int32
    let terminalDescriptor: Int32

    init() throws {
        var controller: Int32 = -1
        var terminal: Int32 = -1
        guard openpty(&controller, &terminal, nil, nil, nil) == 0 else {
            if controller >= 0 { _ = systemClose(controller) }
            if terminal >= 0 { _ = systemClose(terminal) }
            throw TerminalTestError.couldNotOpen
        }
        controllerDescriptor = controller
        terminalDescriptor = terminal
    }

    func close() {
        _ = systemClose(terminalDescriptor)
        _ = systemClose(controllerDescriptor)
    }
}

private enum TerminalTestError: Error {
    case couldNotOpen
    case expected
}

#if os(Linux)
    private func systemClose(_ descriptor: Int32) -> Int32 {
        Glibc.close(descriptor)
    }
#else
    private func systemClose(_ descriptor: Int32) -> Int32 {
        Darwin.close(descriptor)
    }
#endif
