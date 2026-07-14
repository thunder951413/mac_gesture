import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static func apply(enabled: Bool) throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            if enabled { throw LaunchAtLoginError.requiresApplicationBundle }
            return
        }
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled {
            try service.unregister()
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case requiresApplicationBundle
    var errorDescription: String? { "登录启动需要先将 Gesture.app 安装到“应用程序”文件夹" }
}
