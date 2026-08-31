import Foundation
import XCTest
@testable import TokiAgentCore

final class AgentSenpiMountPreparerTests: XCTestCase {
    func test_absentTaskParentRemainsAbsent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try AgentSenpiMountPreparer.prepare(home: root)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".omo").path))
    }

    func test_existingTaskParentGetsPrivateDelegatedRoots() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskRoot = root.appendingPathComponent(".omo/senpi-task")
        try FileManager.default.createDirectory(at: taskRoot, withIntermediateDirectories: true)

        try AgentSenpiMountPreparer.prepare(home: root)

        for name in ["children", "sessions"] {
            let directory = taskRoot.appendingPathComponent(name)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual(values.isDirectory, true)
            XCTAssertNotEqual(values.isSymbolicLink, true)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }

    func test_symlinkedTaskParentIsRejectedWithoutModifyingTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let omoRoot = root.appendingPathComponent(".omo")
        let sentinel = root.appendingPathComponent("sentinel")
        try FileManager.default.createDirectory(at: omoRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: omoRoot.appendingPathComponent("senpi-task"),
            withDestinationURL: sentinel)

        XCTAssertThrowsError(try AgentSenpiMountPreparer.prepare(home: root)) { error in
            guard case AgentCommandError.unsafeSenpiMountPaths = error else {
                return XCTFail("Expected unsafeSenpiMountPaths, received \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sentinel.appendingPathComponent("children").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sentinel.appendingPathComponent("sessions").path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-senpi-mounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
