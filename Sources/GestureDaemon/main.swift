import Foundation

// 信号处理：信号处理器只设标志位，CFRunLoop timer 定期检查并安全退出
var exitFlag: Int32 = 0

signal(SIGINT) { _ in
    exitFlag = 1
}
signal(SIGTERM) { _ in
    exitFlag = 1
}

let checkTimer = CFRunLoopTimerCreateWithHandler(
    kCFAllocatorDefault, 0, 0.1, 0, 0
) { _ in
    if exitFlag != 0 {
        print("\n[GestureDaemon] 收到退出信号，正在退出...")
        CFRunLoopStop(CFRunLoopGetMain())
    }
}
CFRunLoopAddTimer(CFRunLoopGetMain(), checkTimer, .commonModes)

// --- 默认配置路径 ---
let homeGestureDir = NSString(string: "~/.gesture").expandingTildeInPath
let homeGestureConfig = homeGestureDir + "/config.json"

// --- 命令行参数 ---
let configPath: String
if CommandLine.arguments.count > 1 {
    let arg = (CommandLine.arguments[1] as NSString).expandingTildeInPath
    if arg == "-h" || arg == "--help" {
        printHelp()
        exit(0)
    }
    configPath = arg
} else {
    // 优先级：1) CWD config.json  2) ~/.gesture/config.json  3) auto-create
    let cwdCandidate = FileManager.default.currentDirectoryPath + "/config.json"
    if FileManager.default.fileExists(atPath: cwdCandidate) {
        configPath = cwdCandidate
    } else if FileManager.default.fileExists(atPath: homeGestureConfig) {
        configPath = homeGestureConfig
    } else {
        // 自动创建 ~/.gesture/ 并写入默认配置
        do {
            try FileManager.default.createDirectory(atPath: homeGestureDir, withIntermediateDirectories: true)
            let defaultJSON = defaultConfigJSON()
            try defaultJSON.write(toFile: homeGestureConfig, atomically: true, encoding: .utf8)
            print("[GestureDaemon] 已在 \(homeGestureConfig) 创建默认配置")
            configPath = homeGestureConfig
        } catch {
            print("[GestureDaemon] 创建默认配置失败: \(error.localizedDescription)")
            configPath = ""
        }
    }
}

// --- 加载配置 ---
let appConfig: Config
if configPath.isEmpty {
    print("[GestureDaemon] 使用内置默认配置")
    appConfig = Config(defaultConfig: true)
} else {
    do {
        appConfig = try Config(path: configPath)
        print("[GestureDaemon] 已加载: \(configPath)")
    } catch {
        print("[GestureDaemon] 配置加载失败: \(error.localizedDescription)，使用默认配置")
        appConfig = Config(defaultConfig: true)
    }
}

print("[GestureDaemon] 手势映射引擎 v1.0")
print("[GestureDaemon] 按键模拟需要辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能）")
print()

// --- 启动守护进程 ---
let daemon = GestureDaemon(config: appConfig)
do {
    try daemon.start()
    print("[GestureDaemon] 已退出，设备资源已释放")
} catch {
    fputs("[GestureDaemon] 启动失败: \(error.localizedDescription)\n", stderr)
    fputs("\n可能的原因:\n", stderr)
    fputs("  1. 无可用的触控板设备\n", stderr)
    fputs("  2. macOS 版本过低（需要 macOS 13+）\n", stderr)
    fputs("  3. 设备处于异常状态 —— 尝试重新插拔外接触控板\n", stderr)
    fputs("\n使用 -h 查看帮助\n", stderr)
    exit(1)
}

func defaultConfigJSON() -> String {
    return """
{
  "gestures": [
    { "name": "三指下滑关闭窗口", "fingers": 3, "direction": "down",  "minDistance": 0.12, "keys": ["cmd", "w"] }
  ],
  "hotkeys": [
    { "name": "Ctrl+Shift+A → Cmd+C", "when": ["ctrl", "shift", "a"], "send": ["cmd", "c"] },
    { "name": "Ctrl+Shift+X → Cmd+V", "when": ["ctrl", "shift", "x"], "send": ["cmd", "v"] },
    { "name": "Cmd+H → Left", "when": ["cmd", "h"], "send": ["left"] },
    { "name": "Cmd+J → Down", "when": ["cmd", "j"], "send": ["down"] },
    { "name": "Cmd+K → Up",   "when": ["cmd", "k"], "send": ["up"] },
    { "name": "Cmd+L → Right","when": ["cmd", "l"], "send": ["right"] }
  ],
  "settings": {
    "debounceMs": 150,
    "logLevel": "info",
    "diagonalRejectRatio": 0.95,
    "downBiasRatio": 0.35
  }
}
"""
}

func printHelp() {
    print("""
        GestureDaemon - macOS 触控板手势映射工具

        用法: gesture-daemon [config.json]

        支持的手势方向: up  down  left  right  pinch  spread
        支持的修饰键:   cmd command  shift  option opt alt  ctrl control  fn function
        支持的普通键:   a-z  0-9  f1-f12  space  return  tab  escape  left right up down

        示例配置:
        {
          "gestures": [
            {
              "name": "三指下滑关闭窗口",
              "fingers": 3,
              "direction": "down",
              "minDistance": 0.15,
              "keys": ["cmd", "w"]
            }
          ],
          "settings": {
            "debounceMs": 300,
            "logLevel": "info"
          }
        }

        系统要求: macOS 13+, 触控板, 辅助功能权限
        配置文件: ~/.gesture/config.json
        """)
}
