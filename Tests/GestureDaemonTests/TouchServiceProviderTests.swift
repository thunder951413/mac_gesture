import XCTest
@testable import GestureDaemon

final class TouchServiceProviderTests: XCTestCase {
    private func executable(_ script: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testStartupWatchdogReportsOneFailure() async throws {
        let url = try executable("exec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: url) }
        let failed = expectation(description: "startup timeout")
        let provider = await MainActor.run { TouchServiceProvider(executableURL: url, startupTimeout: 0.1) }
        await MainActor.run {
            provider.onStateChange = { state in
                if case .failed(let reason) = state { XCTAssertTrue(reason.contains("超时")); failed.fulfill() }
            }
        }
        try await MainActor.run { try provider.start() }
        await fulfillment(of: [failed], timeout: 3)
        await MainActor.run { provider.stop() }
    }

    func testStopDoesNotWaitForUnresponsiveProcessOrDeliverStaleEvents() async throws {
        let url = try executable("trap '' TERM\nprintf '{\"kind\":\"ready\"}\\n'\nexec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: url) }
        let ready = expectation(description: "ready")
        let stale = expectation(description: "stopped provider has no events")
        stale.isInverted = true
        let provider = await MainActor.run { TouchServiceProvider(executableURL: url) }
        await MainActor.run {
            provider.onStateChange = { state in if case .advanced = state { ready.fulfill() } }
        }
        try await MainActor.run { try provider.start() }
        await fulfillment(of: [ready], timeout: 3)
        await MainActor.run {
            provider.onStateChange = { _ in stale.fulfill() }
            provider.onFrame = { _, _ in stale.fulfill() }
            let began = Date()
            provider.stop()
            XCTAssertLessThan(Date().timeIntervalSince(began), 0.2)
        }
        await fulfillment(of: [stale], timeout: 2.2)
    }
}
