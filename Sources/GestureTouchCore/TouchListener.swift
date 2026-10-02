import Foundation
import CoreGraphics

public final class TouchListener {
    public typealias TouchCallback = ([ActiveTouch], Double) -> Void

    fileprivate var onTouch: TouchCallback
    private var deviceArray: CFArray?
    private var devicePointers: [UnsafeMutableRawPointer] = []
    private var usesRefconCallback = false
    private var invalidFrameCount = 0
    private var lastTimestamps: [UInt: Double] = [:]
    private var activeDevice: UInt?
    private let frameworkHandle: UnsafeMutableRawPointer

    fileprivate static let maxFingers = 20
    // MT 回调在框架内部线程触发，多设备时并发；所有静态与实例帧状态都经此锁串行化。
    private static let listenerState = ListenerState()

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
        do { try findAndStartDevice() }
        catch { stopDevice(); throw error }
    }

    deinit { stopDevice() }

    // MARK: - Callbacks

    private static let callback: MTContactCallback = { device, data, n, ts, _ in
        processTouches(device: device, data: data, nFingers: n, ts: ts)
        return 0
    }

    private static let callbackWithRefcon: MTContactCallbackWithRefcon = { device, data, n, ts, _, _ in
        processTouches(device: device, data: data, nFingers: n, ts: ts)
        return 0
    }

    private static func processTouches(device: UnsafeMutableRawPointer?, data: UnsafeMutableRawPointer?,
                                        nFingers: Int32, ts: Double) {
        listenerState.lock.lock()
        defer { listenerState.lock.unlock() }

        // 使用受锁保护的弱引用，避免注销后迟到的 refcon 回调访问释放的实例。
        guard let l = listenerState.listener, let device else { return }
        let deviceID = UInt(bitPattern: device)

        guard ts.isFinite, ts >= 0, ts >= (l.lastTimestamps[deviceID] ?? 0) else {
            l.registerInvalidFrame("时间戳异常: \(ts)")
            return
        }
        guard nFingers >= 0, nFingers <= maxFingers, nFingers == 0 || data != nil else {
            l.registerInvalidFrame("异常手指数量: \(nFingers)")
            return
        }

        if nFingers == 0 {
            l.lastTimestamps[deviceID] = ts
            l.invalidFrameCount = 0
            if l.activeDevice == deviceID {
                l.onTouch([], ProcessInfo.processInfo.systemUptime)
                l.activeDevice = nil
            }
            return
        }
        guard let data else { return }

        let touches: [ActiveTouch]
        do {
            touches = try MTContactDecoder.decode(
                UnsafeRawBufferPointer(start: data, count: Int(nFingers) * MTContactDecoder.stride),
                count: Int(nFingers)
            )
        } catch {
            l.registerInvalidFrame(error.localizedDescription)
            return
        }
        l.invalidFrameCount = 0
        l.lastTimestamps[deviceID] = ts
        // 一次手势只属于一个设备，第二块触控板的空帧不会结束当前手势。
        if l.activeDevice == nil { l.activeDevice = deviceID }
        if l.activeDevice == deviceID { l.onTouch(touches, ProcessInfo.processInfo.systemUptime) }
    }

    private func registerInvalidFrame(_ reason: String) {
        invalidFrameCount += 1
        fputs("[TouchListener] 数据验证失败 \(invalidFrameCount)/5：\(reason)\n", stderr)
        if invalidFrameCount >= 5 {
            fputs("[TouchListener] 连续异常，停止高级触控板服务以触发兼容模式\n", stderr)
            exit(3)
        }
    }

    // listener 的所有读写均持有 lock；盒子本身以不可变 static let 发布。
    private final class ListenerState: @unchecked Sendable {
        let lock = NSLock()
        weak var listener: TouchListener?
    }

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
        TouchListener.listenerState.lock.lock()
        TouchListener.listenerState.listener = self
        TouchListener.listenerState.lock.unlock()
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
        TouchListener.listenerState.lock.lock()
        if TouchListener.listenerState.listener === self { TouchListener.listenerState.listener = nil }
        TouchListener.listenerState.lock.unlock()
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
        fputs("[TouchListener] 资源已回收\n", stderr)
    }
}

public struct TouchError: LocalizedError {
    public let message: String
    public init(_ m: String) { self.message = m }
    public var errorDescription: String? { message }
}

public struct ActiveTouch: Codable, Sendable {
    public let identifier: Int
    public let state: Int
    public let normalizedX: CGFloat
    public let normalizedY: CGFloat
    /// 私有框架的接触椭圆与面积代理值，单位依设备而定；旧消息可不提供。
    public let majorAxis: CGFloat?
    public let minorAxis: CGFloat?
    public let contactSize: CGFloat?
    // MTContact 的 makeTouch/touching 才是实际接触；悬停与抬起残留不计入手指。
    public var isTouching: Bool { state == 3 || state == 4 }

    public init(identifier: Int, state: Int, normalizedX: CGFloat, normalizedY: CGFloat,
                majorAxis: CGFloat? = nil, minorAxis: CGFloat? = nil,
                contactSize: CGFloat? = nil) {
        self.identifier = identifier
        self.state = state
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.majorAxis = majorAxis
        self.minorAxis = minorAxis
        self.contactSize = contactSize
    }
}
