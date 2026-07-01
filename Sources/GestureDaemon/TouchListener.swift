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

final class TouchListener {
    typealias TouchCallback = ([ActiveTouch], Double) -> Void

    fileprivate var onTouch: TouchCallback
    private var deviceArray: CFArray?
    private var devicePtr_: UnsafeMutableRawPointer?
    private let frameworkHandle: UnsafeMutableRawPointer

    fileprivate static let maxFingers = 20
    fileprivate static var frameCount: Int32 = 0

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

    init(callback: @escaping TouchCallback) throws {
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
        let listener: TouchListener?
        if let r = refcon {
            listener = Unmanaged<TouchListener>.fromOpaque(r).takeUnretainedValue()
        } else {
            listener = activeListener
        }
        guard let l = listener else { return }
        guard let data = data, nFingers > 0 else { l.onTouch([], ts); return }

        guard nFingers <= maxFingers else {
            fputs("[TouchListener] 异常手指数量: \(nFingers)，已忽略\n", stderr)
            l.onTouch([], ts)
            return
        }

        frameCount += 1
        var touches = [ActiveTouch]()
        touches.reserveCapacity(Int(nFingers))
        let p = data.assumingMemoryBound(to: UInt8.self)
        let sz = MTFingerLayout.structSize
        for i in 0..<Int(nFingers) {
            let b = p.advanced(by: i * sz)
            let ident = Int(readInt32(b, offset: MTFingerLayout.offsetIdentifier))
            let state = Int(readInt32(b, offset: MTFingerLayout.offsetState))
            let x = CGFloat(readFloat(b, offset: MTFingerLayout.offsetX))
            let y = CGFloat(readFloat(b, offset: MTFingerLayout.offsetY))

            // 全量坐标合理性校验：私有结构体布局若跨版本变化会读到越界值，
            // 此时丢弃整帧，避免空触点被误判为真实抬手并提前触发手势。
            if !MTFingerLayout.isCoordValid(x, y) {
                if frameCount <= 3 {
                    fputs("[TouchListener] 坐标异常已丢弃 (i=\(i) x:\(x) y:\(y)) — 偏移量可能需要调整\n", stderr)
                }
                return
            }
            touches.append(ActiveTouch(identifier: ident, state: state,
                                        normalizedX: x, normalizedY: y))
        }
        l.onTouch(touches, ts)
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

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for di in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(arr, di) else { continue }
            let p = UnsafeMutableRawPointer(mutating: raw)

            // Strategy 1: Register → Start (correct order)
            if let regFn: RegVoid = sym("MTRegisterContactFrameCallback"),
               let startFn: DeviceCtrl = sym("MTDeviceStart") {
                regFn(p, TouchListener.callback)
                usleep(50_000)  // small delay after registration
                startFn(p, 0)
                deviceArray = arr; devicePtr_ = p
                TouchListener.activeListener = self
                fputs("[TouchListener] ✅ 设备[\(di)] register-then-start\n", stderr); return
            }

            // Strategy 2: WithRefcon variant (for older macOS)
            if let regRef: RegRefcon = sym("MTRegisterContactFrameCallbackWithRefcon"),
               let startRef: DeviceCtrl = sym("MTDeviceStart") {
                regRef(p, TouchListener.callbackWithRefcon, refcon)
                usleep(50_000)
                startRef(p, 0)
                deviceArray = arr; devicePtr_ = p
                TouchListener.activeListener = self
                fputs("[TouchListener] ✅ 设备[\(di)] with-refcon\n", stderr); return
            }

            // Strategy 3: Legacy — try unregister before register (device may be in bad state)
            typealias Unreg5 = @convention(c) (UnsafeMutableRawPointer, MTContactCallback?) -> Void
            typealias Unreg6 = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackWithRefcon?) -> Void
            let ureg5: Unreg5? = sym("MTUnregisterContactFrameCallback")
            let ureg6: Unreg6? = sym("MTUnregisterContactFrameCallback")
            let regFn: RegVoid? = sym("MTRegisterContactFrameCallback")
            let startFn: DeviceCtrl? = sym("MTDeviceStart")

            for attempt in 1...5 {
                // Clear any stale callbacks
                ureg5?(p, nil)
                ureg6?(p, nil)
                usleep(200_000)
                if let r = regFn, let s = startFn {
                    r(p, TouchListener.callback)
                    usleep(50_000)
                    s(p, 0)
                    deviceArray = arr; devicePtr_ = p
                    TouchListener.activeListener = self
                    fputs("[TouchListener] ✅ 设备[\(di)] legacy-strategy attempt-\(attempt)\n", stderr); return
                }
            }
        }

        throw TouchError("注册失败。如需重置触控板驱动状态请重启电脑")
    }

    private func stopDevice() {
        guard let p = devicePtr_ else { return }
        typealias U5 = @convention(c) (UnsafeMutableRawPointer, MTContactCallback?) -> Void
        typealias U6 = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackWithRefcon?) -> Void
        typealias DC = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

        (sym("MTUnregisterContactFrameCallback") as U5?)?(p, nil)
        (sym("MTUnregisterContactFrameCallback") as U6?)?(p, nil)
        usleep(500_000)
        (sym("MTDeviceStop") as DC?)?(p, 0)
        deviceArray = nil
        devicePtr_ = nil
        TouchListener.activeListener = nil
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

struct TouchError: LocalizedError {
    let message: String
    init(_ m: String) { self.message = m }
    var errorDescription: String? { message }
}

struct ActiveTouch {
    let identifier: Int
    let state: Int
    let normalizedX: CGFloat
    let normalizedY: CGFloat
}
