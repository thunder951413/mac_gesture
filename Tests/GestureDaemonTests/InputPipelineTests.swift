import XCTest
import AppKit
import GestureTouchCore
@testable import GestureDaemon

final class InputPipelineTests: XCTestCase {
    private func line(_ message: TouchServiceMessage) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        return data
    }

    func testStreamHandlesFragmentedAndBatchedMessages() throws {
        let decoder = TouchServiceStreamDecoder()
        let ready = try line(TouchServiceMessage(kind: .ready))
        let frame = try line(TouchServiceMessage(kind: .frame, timestamp: 1, touches: []))
        XCTAssertTrue(try decoder.consume(ready.prefix(4)).isEmpty)
        let messages = try decoder.consume(ready.dropFirst(4) + frame)
        XCTAssertEqual(messages.map(\.kind), [.ready, .frame])
    }

    func testStreamRejectsMalformedOversizedAndInvalidFrames() throws {
        XCTAssertThrowsError(try TouchServiceStreamDecoder().consume(Data("bad JSON\n".utf8)))
        XCTAssertThrowsError(try TouchServiceStreamDecoder().consume(Data(repeating: 65, count: 65_537)))
        let touch = ActiveTouch(identifier: 1, state: 4, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertThrowsError(try TouchServiceStreamDecoder().consume(line(TouchServiceMessage(kind: .frame, timestamp: 1, touches: [touch, touch]))))
        XCTAssertThrowsError(try TouchServiceStreamDecoder().consume(line(TouchServiceMessage(kind: .frame, timestamp: 1))))
        let decoder = TouchServiceStreamDecoder()
        _ = try decoder.consume(line(TouchServiceMessage(kind: .frame, timestamp: 2, touches: [])))
        XCTAssertThrowsError(try decoder.consume(line(TouchServiceMessage(kind: .frame, timestamp: 1, touches: []))))
        XCTAssertFalse(TouchFrameValidator.isValid([ActiveTouch(identifier: 1, state: 4, normalizedX: .nan, normalizedY: 0.5)]))
    }

    func testShapeMetricsSurviveIPCAndOldFramesRemainCompatible() throws {
        let touch = ActiveTouch(identifier: 1, state: 4, normalizedX: 0.5, normalizedY: 0.5,
                                majorAxis: 21, minorAxis: 12, contactSize: 4)
        let frame = TouchServiceMessage(kind: .frame, timestamp: 1, touches: [touch])
        let decoded = try XCTUnwrap(TouchServiceStreamDecoder().consume(line(frame)).first?.touches?.first)
        XCTAssertEqual(decoded.majorAxis, 21)
        XCTAssertEqual(decoded.minorAxis, 12)
        XCTAssertEqual(decoded.contactSize, 4)
        let old = Data("{\"kind\":\"frame\",\"timestamp\":1,\"touches\":[{\"identifier\":1,\"state\":4,\"normalizedX\":0.5,\"normalizedY\":0.5}]}\n".utf8)
        let legacy = try XCTUnwrap(TouchServiceStreamDecoder().consume(old).first?.touches?.first)
        XCTAssertNil(legacy.majorAxis)
        XCTAssertFalse(TouchFrameValidator.isValid([
            ActiveTouch(identifier: 1, state: 4, normalizedX: 0.5, normalizedY: 0.5, majorAxis: .infinity)
        ]))
    }

    func testCancelledAndMomentumScrollDoNotProduceGestures() {
        var accumulator = PublicGestureAccumulator()
        XCTAssertNil(accumulator.scroll(dx: 0.2, dy: 0, phase: .began))
        XCTAssertNil(accumulator.scroll(dx: 0, dy: 0, phase: .cancelled))
        XCTAssertNil(accumulator.scroll(dx: 0.5, dy: 0, phase: .changed, momentum: .began))
        XCTAssertNil(accumulator.scroll(dx: 0, dy: 0, phase: .ended))
        XCTAssertNil(accumulator.scroll(dx: 0.2, dy: 0, phase: .began))
        let gesture = accumulator.scroll(dx: 0.1, dy: 0, phase: .ended)
        XCTAssertEqual(gesture?.direction, .right)
        XCTAssertEqual(gesture!.distance, 0.3, accuracy: 0.0001)
    }

    func testCancelledAndEmptyMagnificationDoNotTrigger() {
        var accumulator = PublicGestureAccumulator()
        XCTAssertNil(accumulator.magnify(0.2, phase: .began))
        XCTAssertNil(accumulator.magnify(0, phase: .cancelled))
        XCTAssertNil(accumulator.magnify(0, phase: .ended))
        XCTAssertNil(accumulator.magnify(-0.1, phase: .began))
        XCTAssertEqual(accumulator.magnify(-0.1, phase: .ended)?.direction, .pinch)
    }

    func testValidatorDetectsAliasesAndOverlappingScopes() {
        var first = AutomationRule(name: "全局", trigger: .keyboard(KeyboardTrigger(keys: ["cmd", "return"])), actions: [.keyboard(["space"])])
        var second = AutomationRule(name: "局部", trigger: .keyboard(KeyboardTrigger(keys: ["command", "enter"], phase: .keyUp)), actions: [.keyboard(["space"])])
        second.applicationScope = ApplicationScope(mode: .include, bundleIdentifiers: ["com.example.App"])
        let configuration = AutomationConfiguration(rules: [first, second], settings: EngineSettings())
        XCTAssertTrue(ConfigurationValidator.warnings(for: configuration).contains { $0.contains("范围重叠") })
        first.applicationScope = ApplicationScope(mode: .exclude, bundleIdentifiers: ["com.example.App"])
        XCTAssertFalse(first.applicationScope.overlaps(second.applicationScope))
        second.actions = [.keyboard(["space", "unknown"])]
        XCTAssertFalse(ConfigurationValidator.isExecutable(second))
    }
}
