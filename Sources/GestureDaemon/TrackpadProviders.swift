import Foundation
import AppKit
import GestureTouchCore

enum TrackpadProviderState {
    case starting
    case advanced
    case compatible(String)
    case failed(String)
}

@MainActor
final class TouchServiceProvider {
    typealias FrameHandler = ([ActiveTouch], Double) -> Void

    var onFrame: FrameHandler?
    var onStateChange: ((TrackpadProviderState) -> Void)?

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var sessionID = UUID()
    private var didFail = false
    private var startupWatchdog: ServiceWatchdog?
    private let executableOverride: URL?
    private let startupTimeout: TimeInterval

    init(executableURL: URL? = nil, startupTimeout: TimeInterval = 5) {
        executableOverride = executableURL
        self.startupTimeout = startupTimeout
    }

    func start() throws {
        stop()
        guard let executableURL = executableOverride ?? Self.executableURL else {
            throw ProviderError("找不到 GestureTouchService")
        }
        let session = sessionID
        didFail = false
        let process = Process()
        let pipe = Pipe()
        let errors = Pipe()
        let decoder = TouchServiceStreamDecoder()
        let errorOutput = ServiceErrorOutput()
        let decodeQueue = DispatchQueue(label: "com.gesture.touch-service.decode")
        process.executableURL = executableURL
        process.standardOutput = pipe
        process.standardError = errors
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            decodeQueue.async { [weak self] in
                do {
                    let messages = try decoder.consume(data)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sessionID == session, !self.didFail else { return }
                        for message in messages {
                            guard self.sessionID == session else { return }
                            self.receive(message)
                        }
                    }
                } catch {
                    let reason = error.localizedDescription
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sessionID == session else { return }
                        self.fail(reason)
                    }
                }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            errorOutput.append(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            let detail = errorOutput.tail
            let reason = "高级触控板服务已退出（状态码 \(process.terminationStatus)）" + (detail.isEmpty ? "" : "：\(detail)")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionID == session else { return }
                self.fail(reason)
            }
        }
        self.process = process
        outputPipe = pipe
        errorPipe = errors
        onStateChange?(.starting)
        do { try process.run() }
        catch { stop(); throw error }
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.sessionID == session else { return }
            self.fail("高级触控板服务启动超时")
        }
        startupWatchdog = ServiceWatchdog(item: watchdog)
        DispatchQueue.main.asyncAfter(deadline: .now() + startupTimeout, execute: watchdog)
    }

    func stop() {
        sessionID = UUID()
        startupWatchdog?.cancel()
        startupWatchdog = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process { ManagedProcess.terminate(process) }
        process = nil
        outputPipe = nil
        errorPipe = nil
    }

    private func receive(_ message: TouchServiceMessage) {
        guard !didFail else { return }
        switch message.kind {
        case .ready:
            startupWatchdog?.cancel()
            startupWatchdog = nil
            onStateChange?(.advanced)
        case .frame:
            if let touches = message.touches, let timestamp = message.timestamp { onFrame?(touches, timestamp) }
        case .error:
            fail(message.message ?? "高级触控板服务发生未知错误")
        }
    }

    private func fail(_ reason: String) {
        guard !didFail else { return }
        didFail = true
        startupWatchdog?.cancel()
        if let process { ManagedProcess.terminate(process) }
        onStateChange?(.failed(reason))
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

    deinit {
        startupWatchdog?.cancel()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process { ManagedProcess.terminate(process) }
    }
}

// DispatchWorkItem.cancel() 本身线程安全，释放 provider 时也可以取消计时任务。
private struct ServiceWatchdog: @unchecked Sendable {
    let item: DispatchWorkItem
    func cancel() { item.cancel() }
}

private final class ServiceErrorOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > 4_000 { data = Data(data.suffix(4_000)) }
    }

    var tail: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
    }
}

final class PublicGestureProvider {
    var onGesture: ((GestureEvent) -> Void)?
    private var monitor: Any?
    private var localMonitor: Any?
    private var accumulator = PublicGestureAccumulator()

    @discardableResult
    func start() -> Bool {
        stop()
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .swipe, .magnify]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.handle(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        return monitor != nil && localMonitor != nil
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
        accumulator = PublicGestureAccumulator()
    }

    private func handle(_ event: NSEvent) {
        let gesture: GestureEvent?
        switch event.type {
        case .scrollWheel:
            guard event.hasPreciseScrollingDeltas else { return }
            gesture = accumulator.scroll(dx: event.scrollingDeltaX / 500, dy: event.scrollingDeltaY / 500,
                                         phase: event.phase, momentum: event.momentumPhase)
        case .swipe:
            gesture = PublicGestureAccumulator.swipe(dx: event.deltaX / 10, dy: event.deltaY / 10)
        case .magnify:
            gesture = accumulator.magnify(event.magnification, phase: event.phase)
        default: return
        }
        if let gesture { onGesture?(gesture) }
    }

    deinit { stop() }
}

struct ProviderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
