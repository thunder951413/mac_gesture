import XCTest
import GestureTouchCore
@testable import GestureDaemon

final class GestureTraceTests: XCTestCase {
    func testTraceBufferLimitsBothFrameCountAndAge() {
        var buffer = GestureTraceBuffer()
        for frame in 0..<1_000 { buffer.append([], timestamp: Double(frame) * 0.001) }
        XCTAssertEqual(buffer.frames.count, 192)
        buffer.append([], timestamp: 5)
        XCTAssertEqual(buffer.frames.count, 1)
        buffer.reset()
        XCTAssertTrue(buffer.frames.isEmpty)
    }

    func testTraceLogRotatesAndPreservesReplayableFrames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = GestureTrace(decision: .ruleTriggered, fingers: 3, direction: .down,
                                 distance: 0.1, dx: 0, dy: -0.1, motions: [],
                                 frames: [TouchServiceMessage(kind: .frame, timestamp: 1,
                                    touches: [ActiveTouch(identifier: 1, state: 4,
                                                          normalizedX: 0.3, normalizedY: 0.5)])])
        let log = GestureTraceLog(directoryURL: directory, maximumBytes: 800)
        for _ in 0..<10 { log.write(trace) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["touch-traces.jsonl", "touch-traces.old.jsonl"])
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, 800)
            for line in data.split(separator: 0x0A) {
                let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                XCTAssertNotNil(record["recordedAt"])
                let storedTrace = try XCTUnwrap(record["trace"] as? [String: Any])
                let restored = try JSONDecoder().decode(GestureTrace.self, from: JSONSerialization.data(withJSONObject: storedTrace))
                XCTAssertEqual(restored.frames.first?.touches?.first?.identifier, 1)
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: log.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
