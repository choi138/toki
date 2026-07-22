import Foundation
import TokiSyncProtocol
import XCTest

final class DeploymentConfigurationTests: XCTestCase {
    func test_nginxSnapshotReadBurstSupportsFullDeviceFleetColdSync() throws {
        let configuration = try String(
            contentsOf: repositoryRoot.appendingPathComponent("packaging/nginx/toki-hub.conf.example"),
            encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #"limit_req zone=toki_hub_snapshot_reads burst=(\d+) nodelay;"#)
        let fullRange = NSRange(configuration.startIndex..., in: configuration)
        let match = try XCTUnwrap(expression.firstMatch(in: configuration, range: fullRange))
        let burstRange = try XCTUnwrap(Range(match.range(at: 1), in: configuration))
        let burst = try XCTUnwrap(Int(configuration[burstRange]))

        XCTAssertTrue(configuration.contains("location ~ ^/v1/snapshots"))
        XCTAssertGreaterThanOrEqual(burst, TokiSyncLimits.maximumDevices + 1)
    }

    func test_nginxBulkSnapshotEndpointHasIndependentLowLimits() throws {
        let configuration = try String(
            contentsOf: repositoryRoot.appendingPathComponent("packaging/nginx/toki-hub.conf.example"),
            encoding: .utf8)

        XCTAssertTrue(configuration.contains("location = /v1/snapshots {"))
        XCTAssertTrue(configuration.contains("limit_req zone=toki_hub_bulk_snapshot_reads burst=1 nodelay;"))
        XCTAssertTrue(configuration.contains("limit_conn toki_hub_connections 1;"))
        XCTAssertFalse(configuration.contains("^/v1/snapshots(?:/manifest|/[A-Za-z0-9_-]+)?$"))
    }

    func test_nginxHTTPRedirectUsesConfiguredHostInsteadOfRequestHost() throws {
        let configuration = try String(
            contentsOf: repositoryRoot.appendingPathComponent("packaging/nginx/toki-hub.conf.example"),
            encoding: .utf8)

        XCTAssertTrue(configuration.contains("return 301 https://hub.example.com$request_uri;"))
        XCTAssertFalse(configuration.contains("return 301 https://$host$request_uri;"))
    }

    func test_nginxAllowsLargeBodiesOnlyForSnapshotUploads() throws {
        let configuration = try String(
            contentsOf: repositoryRoot.appendingPathComponent("packaging/nginx/toki-hub.conf.example"),
            encoding: .utf8)

        XCTAssertTrue(configuration.contains("client_max_body_size 64k;"))
        XCTAssertTrue(configuration.contains("location ~ ^/v1/devices/[A-Za-z0-9_-]+/snapshot$ {"))
        XCTAssertTrue(configuration.contains("location ~ ^/v1/devices/[A-Za-z0-9_-]+/heartbeat$ {"))
        XCTAssertEqual(configuration.components(separatedBy: "client_max_body_size 8m;").count - 1, 1)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
