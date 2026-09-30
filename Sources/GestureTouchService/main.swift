import Foundation
import GestureTouchCore

// MultitouchSupport 会把设备诊断写到 stdout。先保留协议管道，再将
// 普通 stdout 重定向到 stderr，保证框架输出不能污染 JSON Lines。
let protocolDescriptor = dup(STDOUT_FILENO)
guard protocolDescriptor >= 0 else { exit(2) }
let protocolOutput = FileHandle(fileDescriptor: protocolDescriptor, closeOnDealloc: true)
guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { exit(2) }

let outputQueue = DispatchQueue(label: "com.gesture.touch-service.output")
let originalParentPID = getppid()

func send(_ message: TouchServiceMessage) {
    outputQueue.sync {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        do { try protocolOutput.write(contentsOf: data) }
        catch { exit(0) }
    }
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let parentWatchdog = DispatchSource.makeTimerSource(queue: .main)
interruptSource.setEventHandler { CFRunLoopStop(CFRunLoopGetMain()) }
terminateSource.setEventHandler { CFRunLoopStop(CFRunLoopGetMain()) }
// Process.terminate() 可以正常关闭服务；主应用崩溃或被强制结束时则没有
// 清理机会。监控父 PID，避免留下继续占用 MultitouchSupport 的孤儿进程。
parentWatchdog.schedule(deadline: .now() + 1, repeating: 1)
parentWatchdog.setEventHandler {
    if getppid() != originalParentPID || getppid() <= 1 {
        CFRunLoopStop(CFRunLoopGetMain())
    }
}
interruptSource.resume()
terminateSource.resume()
parentWatchdog.resume()

do {
    let listener = try TouchListener { touches, timestamp in
        send(TouchServiceMessage(kind: .frame, timestamp: timestamp, touches: touches))
    }
    send(TouchServiceMessage(kind: .ready))
    withExtendedLifetime(listener) { CFRunLoopRun() }
} catch {
    send(TouchServiceMessage(kind: .error, message: error.localizedDescription))
    exit(2)
}
