import Foundation
import CoreGraphics

/// MTFinger 私有结构体的字段偏移量（macOS 14+/26 实测）。
/// 这些是私有 API，布局未公开，集中在此便于跨版本维护与校验。
private enum MTFingerLayout {
    /// 单个 MTFinger 结构体大小（字节）
    static let structSize: Int = 64
    // 字段偏移量
    static let offsetIdentifier: Int = 16
    static let offsetState: Int = 20
    static let offsetX: Int = 32
    static let offsetY: Int = 36
    // 坐标合理性范围（归一化值，触控板外少许裕量）
    static let coordMin: CGFloat = -0.2
    static let coordMax: CGFloat = 1.2
}

public final class TouchListener {
    public typealias TouchCallback = ([ActiveTouch], Double) -> Void

    fileprivate var onTouch: TouchCallback
    private var deviceArray: CFArray?
    private var devicePointers: [UnsafeMutableRawPointer] = []
    private var usesRefconCallback = false
    private var invalidFrameCount = 0
    private var lastTimestamp: Double = 0
    private let frameworkHandle: UnsafeMutableRawPointer

    fileprivate static let maxFingers = 20
    // MT 回调在框架内部线程触发，多设备时并发；所有静态与实例帧状态都经此锁串行化。
    private static let stateLock = NSLock()

    // MARK: - Correct callback signatures (macOS 14+ / 26)

    /// 5-param callback: (device, touches, numTouches, timestamp, frame) → Int32
    typealias MTContactCallback = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        Int32,
        Double,
        Int32
    ) -> Int32

    /// 6-param callback: (device, touches, numTouches, timestamp, frame, refcon) → Int32
    typealias MTContactCallbackWithRefcon = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        Int32,
        Double,
        Int32,
        UnsafeMutableRawPointer?
    ) -> Int32

    public init(callback: @escaping TouchCallback) throws {
        self.onTouch = callback
        self.frameworkHandle = try TouchListener.loadFramework()
        try findAndStartDevice()
    }

    deinit { stopDevice() }

    // MARK: - Callbacks

    private static let callback: MTContactCallback = { _, data, n, ts, _ in
        processTouches(data: data, nFingers: n, ts: ts, refcon: nil)
        return 0
    }

    private static let callbackWithRefcon: MTContactCallbackWithRefcon = { _, data, n, ts, _, refcon in
        processTouches(data: data, nFingers: n, ts: ts, refcon: refcon)
        return 0
    }

    private static func processTouches(data: UnsafeMutableRawPointer?,
                                        nFingers: Int32, ts: Double,
                                        refcon: UnsafeMutableRawPointer?) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let listener: TouchListener?
        if let r = refcon {
            listener = Unmanaged<TouchListener>.fromOpaque(r).takeUnretainedValue()
        } else {
            listener = activeListener
        }
        guard let l = listener else { return }
        guard let data = data, nFingers > 0 else { l.onTouch([], ts); return }

        guard ts.isFinite, ts >= l.lastTimestamp else {
            l.registerInvalidFrame("时间戳异常: \(ts)")
            return
        }
        l.lastTimestamp = ts

        guard nFingers <= maxFingers else {
            l.registerInvalidFrame("异常手指数量: \(nFingers)")
            l.onTouch([], ts)
            return
        }

        var touches = [ActiveTouch]()
        touches.reserveCapacity(Int(nFingers))
        let p = data.assumingMemoryBound(to: UInt8.self)
        let sz = MTFingerLayout.structSize
        var identifiers = Set<Int>()
        for i in 0..<Int(nFingers) {
            let b = p.advanced(by: i * sz)
            let ident = Int(readInt32(b, offset: MTFingerLayout.offsetIdentifier))
            let state = Int(readInt32(b, offset: MTFingerLayout.offsetState))
            let x = CGFloat(readFloat(b, offset: MTFingerLayout.offsetX))
            let y = CGFloat(readFloat(b, offset: MTFingerLayout.offsetY))

            guard (-1...128).contains(ident), identifiers.insert(ident).inserted else {
                l.registerInvalidFrame("触点标识异常或重复: \(ident)")
                return
            }

            // 全量坐标合理性校验：私有结构体布局若跨版本变化会读到越界值，
            // 此时丢弃整帧，避免空触点被误判为真实抬手并提前触发手势。
            if !MTFingerLayout.isCoordValid(x, y) {
                l.registerInvalidFrame("坐标异常 (i=\(i) x:\(x) y:\(y))，结构体布局可能已变化")
                return
            }
            touches.append(ActiveTouch(identifier: ident, state: state,
                                        normalizedX: x, normalizedY: y))
        }
        l.invalidFrameCount = 0
        l.onTouch(touches, ts)
    }

    private func registerInvalidFrame(_ reason: String) {
        invalidFrameCount += 1
        fputs("[TouchListener] 数据验证失败 \(invalidFrameCount)/5：\(reason)\n", stderr)
        if invalidFrameCount >= 5 {
            fputs("[TouchListener] 连续异常，停止高级触控板服务以触发兼容模式\n", stderr)
            exit(3)
        }
    }

    // MARK: - Struct field readers

    private static func readInt32(_ base: UnsafePointer<UInt8>, offset: Int) -> Int32 {
        base.advanced(by: offset).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
    }

    private static func readFloat(_ base: UnsafePointer<UInt8>, offset: Int) -> Float {
        base.advanced(by: offset).withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
    }

    fileprivate static weak var activeListener: TouchListener?

    // MARK: - Framework

    private static func loadFramework() throws -> UnsafeMutableRawPointer {
        fputs("[TouchListener] 系统: \(ProcessInfo.processInfo.operatingSystemVersionString)\n", stderr)
        let f = "MultitouchSupport.framework"
        for p in [
            "/System/Library/PrivateFrameworks/\(f)/MultitouchSupport",
            "/System/Library/PrivateFrameworks/\(f)/Versions/Current/MultitouchSupport"
        ] {
            if let h = dlopen(p, RTLD_LAZY | RTLD_LOCAL) {
                fputs("[TouchListener] 加载: \(p)\n", stderr)
                return h
            }
            if let err = dlerror() {
                fputs("[TouchListener] dlopen 失败 (\(p)): \(String(cString: err))\n", stderr)
            }
        }
        throw TouchError("无法加载 \(f)")
    }

    private func sym<T>(_ n: String) -> T? {
        guard let s = dlsym(frameworkHandle, n) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    // MARK: - Device connection

    private func findAndStartDevice() throws {
        typealias CreateFn = @convention(c) () -> Unmanaged<CFArray>?

        // Registration functions — void return (macOS 26 may return void)
        typealias RegVoid   = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
        typealias RegRefcon = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackWithRefcon, UnsafeMutableRawPointer?) -> Void

        // Device control — void return
        typealias DeviceCtrl = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

        guard let create: CreateFn = sym("MTDeviceCreateList") else { throw TouchError("MTDeviceCreateList") }

        guard let arr = create()?.takeRetainedValue() else { throw TouchError("未检测到触控板") }
        let count = CFArrayGetCount(arr)
        fputs("[TouchListener] 发现 \(count) 个设备\n", stderr)
        guard count > 0 else { throw TouchError("设备列表为空") }

        guard let start: DeviceCtrl = sym("MTDeviceStart") else { throw TouchError("MTDeviceStart") }
        let regular: RegVoid? = sym("MTRegisterContactFrameCallback")
        let withRefcon: RegRefcon? = sym("MTRegisterContactFrameCallbackWithRefcon")
        guard regular != nil || withRefcon != nil else { throw TouchError("找不到触点回调注册函数") }

        deviceArray = arr
        TouchListener.stateLock.lock()
        TouchListener.activeListener = self
        TouchListener.stateLock.unlock()
        usesRefconCallback = regular == nil
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(arr, index) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: raw)
            if let regular { regular(pointer, TouchListener.callback) }
            else { withRefcon?(pointer, TouchListener.callbackWithRefcon, refcon) }
            usleep(50_000)
            start(pointer, 0)
            devicePointers.append(pointer)
            fputs("[TouchListener] ✅ 已监听设备[\(index)]\n", stderr)
        }
        if devicePointers.isEmpty { throw TouchError("没有可注册的触控板") }
    }

    private func stopDevice() {
        guard !devicePointers.isEmpty else { return }
        typealias U5 = @convention(c) (UnsafeMutableRawPointer, MTContactCallback?) -> Void
        typealias U6 = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackWithRefcon?) -> Void
        typealias DC = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

        let unregister5: U5? = sym("MTUnregisterContactFrameCallback")
        let unregister6: U6? = sym("MTUnregisterContactFrameCallback")
        let stop: DC? = sym("MTDeviceStop")
        for pointer in devicePointers {
            if usesRefconCallback { unregister6?(pointer, TouchListener.callbackWithRefcon) }
            else { unregister5?(pointer, TouchListener.callback) }
            usleep(20_000)
            stop?(pointer, 0)
        }
        deviceArray = nil
        devicePointers.removeAll()
        TouchListener.stateLock.lock()
        TouchListener.activeListener = nil
        TouchListener.stateLock.unlock()
        fputs("[TouchListener] 资源已回收\n", stderr)
    }
}

private extension MTFingerLayout {
    /// 坐标是否在合理范围内。归一化坐标通常在 [0,1]，
    /// 触控板边缘允许少许越界，但远超此范围说明结构体偏移可能错误。
    static func isCoordValid(_ x: CGFloat, _ y: CGFloat) -> Bool {
        x >= coordMin && x <= coordMax && y >= coordMin && y <= coordMax
    }
}

public struct TouchError: LocalizedError {
    public let message: String
    public init(_ m: String) { self.message = m }
    public var errorDescription: String? { message }
}

public struct ActiveTouch: Codable {
    public let identifier: Int
    public let state: Int
    public let normalizedX: CGFloat
    public let normalizedY: CGFloat

    public init(identifier: Int, state: Int, normalizedX: CGFloat, normalizedY: CGFloat) {
        self.identifier = identifier
        self.state = state
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
    }
}
