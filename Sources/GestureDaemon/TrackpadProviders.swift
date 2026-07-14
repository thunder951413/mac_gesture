import Foundation
import AppKit
import GestureTouchCore

enum TrackpadProviderState {
    case starting
    case advanced
    case compatible(String)
    case failed(String)
}

final class TouchServiceProvider {
    typealias FrameHandler = ([ActiveTouch], Double) -> Void

    var onFrame: FrameHandler?
    var onStateChange: ((TrackpadProviderState) -> Void)?

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var buffer = Data()
    private var recentErrorOutput = ""
    private let errorLock = NSLock()
    private let decodeQueue = DispatchQueue(label: "com.gesture.touch-service.decode")
    private var stopping = false

    func start() throws {
        stop()
        errorLock.lock(); recentErrorOutput = ""; errorLock.unlock()
        guard let executableURL = Self.executableURL else {
            throw ProviderError("找不到 GestureTouchService")
        }
        stopping = false
        let process = Process()
        let pipe = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.standardOutput = pipe
        process.standardError = errors
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.decodeQueue.async { self?.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendErrorOutput(text)
        }
        process.terminationHandler = { [weak self] process in
            guard let self, !self.stopping else { return }
            let detail = self.errorOutputTail()
            let reason = "高级触控板服务已退出（状态码 \(process.terminationStatus)）" + (detail.isEmpty ? "" : "：\(detail)")
            DispatchQueue.main.async { self.onStateChange?(.failed(reason)) }
        }
        self.process = process
        outputPipe = pipe
        errorPipe = errors
        onStateChange?(.starting)
        try process.run()
    }

    func stop() {
        stopping = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        outputPipe = nil
        errorPipe = nil
        decodeQueue.sync { buffer.removeAll(keepingCapacity: false) }
    }

    private func appendErrorOutput(_ text: String) {
        errorLock.lock()
        recentErrorOutput += text
        if recentErrorOutput.count > 4_000 { recentErrorOutput = String(recentErrorOutput.suffix(4_000)) }
        errorLock.unlock()
    }

    private func errorOutputTail() -> String {
        errorLock.lock(); defer { errorLock.unlock() }
        return recentErrorOutput.split(separator: "\n").last.map(String.init) ?? ""
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let message = try? JSONDecoder().decode(TouchServiceMessage.self, from: Data(line)) else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch message.kind {
                case .ready:
                    self.onStateChange?(.advanced)
                case .frame:
                    if let touches = message.touches, let timestamp = message.timestamp {
                        self.onFrame?(touches, timestamp)
                    }
                case .error:
                    self.onStateChange?(.failed(message.message ?? "高级触控板服务发生未知错误"))
                }
            }
        }
    }

    private static var executableURL: URL? {
        let fileManager = FileManager.default
        if Bundle.main.bundleURL.pathExtension == "app" {
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GestureTouchService")
            if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        if let appExecutable = Bundle.main.executableURL {
            let sibling = appExecutable.deletingLastPathComponent().appendingPathComponent("GestureTouchService")
            if fileManager.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        let debug = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/GestureTouchService")
        return fileManager.isExecutableFile(atPath: debug.path) ? debug : nil
    }

    deinit { stop() }
}

final class PublicGestureProvider {
    var onGesture: ((GestureEvent) -> Void)?
    private var monitor: Any?
    private var scrollDX: CGFloat = 0
    private var scrollDY: CGFloat = 0
    private var magnification: CGFloat = 0

    @discardableResult
    func start() -> Bool {
        stop()
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .swipe, .magnify]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        return monitor != nil
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        reset()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel:
            guard event.hasPreciseScrollingDeltas else { return }
            if event.phase == .began { scrollDX = 0; scrollDY = 0 }
            scrollDX += event.scrollingDeltaX / 500
            scrollDY += event.scrollingDeltaY / 500
            if event.phase == .ended || event.phase == .cancelled {
                emitSwipe(dx: scrollDX, dy: scrollDY)
                scrollDX = 0; scrollDY = 0
            }
        case .swipe:
            emitSwipe(dx: event.deltaX / 10, dy: event.deltaY / 10)
        case .magnify:
            if event.phase == .began { magnification = 0 }
            magnification += event.magnification
            if event.phase == .ended || event.phase == .cancelled {
                let direction: GestureDirection = magnification >= 0 ? .spread : .pinch
                onGesture?(GestureEvent(fingers: 2, direction: direction, distance: abs(magnification), dx: 0, dy: 0))
                magnification = 0
            }
        default:
            break
        }
    }

    private func emitSwipe(dx: CGFloat, dy: CGFloat) {
        let distance = hypot(dx, dy)
        guard distance >= 0.01 else { return }
        let direction: GestureDirection
        if abs(dx) > abs(dy) { direction = dx > 0 ? .right : .left }
        else { direction = dy > 0 ? .up : .down }
        onGesture?(GestureEvent(fingers: 2, direction: direction, distance: distance, dx: dx, dy: dy))
    }

    private func reset() {
        scrollDX = 0; scrollDY = 0; magnification = 0
    }

    deinit { stop() }
}

struct ProviderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
