import XCTest
@testable import GestureDaemon

final class ActionExecutorTests: XCTestCase {
    private func script(_ value: String) -> AutomationAction { AutomationAction(kind: .shellScript, value: value) }

    func testFailureStopsFollowingActionsAndReportsExitCode() async {
        let executor = ActionExecutor(debounceMilliseconds: 0)
        let finished = expectation(description: "failed sequence completed")
        executor.onCompletion = { name, failure in
            XCTAssertEqual(name, "失败序列")
            XCTAssertTrue(failure?.contains("7") == true)
            finished.fulfill()
        }
        // 第二步若错误地继续执行，会等待很久并导致测试超时。
        XCTAssertTrue(executor.execute([script("exit 7"), AutomationAction(kind: .delay, delayMilliseconds: 10_000)], ruleName: "失败序列"))
        await fulfillment(of: [finished], timeout: 3)
        executor.cancel()
    }

    func testCancelInterruptsHugeDelayAndDiscardsQueuedActions() async {
        let executor = ActionExecutor(debounceMilliseconds: 0, maximumPendingExecutions: 2)
        let completed = expectation(description: "cancelled executions must not complete")
        completed.isInverted = true
        executor.onCompletion = { _, _ in completed.fulfill() }
        XCTAssertTrue(executor.execute([AutomationAction(kind: .delay, delayMilliseconds: Int.max)], ruleName: "长等待"))
        XCTAssertTrue(executor.execute([], ruleName: "排队动作"))
        XCTAssertFalse(executor.execute([], ruleName: "队列超限"))
        executor.cancel()
        XCTAssertFalse(executor.execute([], ruleName: "取消后动作"))
        await fulfillment(of: [completed], timeout: 0.2)
    }

    func testCommandsTimeOutWithoutBlockingCaller() async {
        let executor = ActionExecutor(debounceMilliseconds: 0, commandTimeout: 0.1)
        let finished = expectation(description: "timeout reported")
        executor.onCompletion = { _, failure in
            XCTAssertTrue(failure?.contains("超时") == true)
            finished.fulfill()
        }
        let began = Date()
        XCTAssertTrue(executor.execute([script("exec /bin/sleep 10")], ruleName: "超时命令"))
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.1)
        await fulfillment(of: [finished], timeout: 4)
        executor.cancel()
    }

    func testActionsAndQueuedSequencesRunInOrder() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let quoted = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let executor = ActionExecutor(debounceMilliseconds: 0)
        let finished = expectation(description: "two sequences completed")
        finished.expectedFulfillmentCount = 2
        executor.onCompletion = { _, failure in XCTAssertNil(failure); finished.fulfill() }
        executor.execute([script("printf A >> \(quoted)"), AutomationAction(kind: .delay, delayMilliseconds: 20), script("printf B >> \(quoted)")], ruleName: "first")
        executor.execute([script("printf C >> \(quoted)")], ruleName: "second")
        await fulfillment(of: [finished], timeout: 4)
        XCTAssertEqual(try String(contentsOf: url), "ABC")
        executor.cancel()
    }
}
