import XCTest
import Combine
@testable import GestureDaemon

final class GestureDaemonTests: XCTestCase {
    func testManualActionsRunWhenEngineStoppedAndScopeDoesNotMatch() async {
        let engine = await MainActor.run { GestureDaemon() }
        let failed = expectation(description: "manual script executed")
        let observer = await MainActor.run {
            engine.$lastEvent.sink { event in if event.contains("命令退出码：9") { failed.fulfill() } }
        }
        await MainActor.run {
            var rule = AutomationRule(name: "手动测试", isEnabled: false, trigger: .keyboard(KeyboardTrigger()), actions: [AutomationAction(kind: .shellScript, value: "exit 9")])
            rule.applicationScope = ApplicationScope(mode: .include, bundleIdentifiers: ["com.example.NoSuchApplication"])
            engine.testActions(for: rule)
            XCTAssertFalse(engine.isEnabled)
        }
        await fulfillment(of: [failed], timeout: 3)
        await MainActor.run { observer.cancel(); engine.stop() }
    }

    func testManualInvalidActionsAreReportedWithoutExecution() async {
        await MainActor.run {
            let engine = GestureDaemon()
            let rule = AutomationRule(name: "无效测试", trigger: .keyboard(KeyboardTrigger()), actions: [.keyboard(["cmd", "unknown"])])
            engine.testActions(for: rule)
            XCTAssertTrue(engine.lastEvent.contains("动作为空或无效"))
            XCTAssertFalse(engine.isRunning)
            engine.stop()
        }
    }
}
