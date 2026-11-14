import AppKit
import MUCore

/// Активация программы по pid — и программы ИИ на время щелчка, и программы пользователя после него.
/// Успех — только если она действительно стала `frontmostApplication` (14.11: `NSApp.isActive` дал ложный «успех»,
/// активным остался Claude). Обычная активация не сработала — закрытая SkyLight, как AltTab и yabai.
@MainActor
enum Activator {
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias GetProcess = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    /// `_SLPSSetFrontProcessWithOptions(psn, windowID, kCPSUserGenerated)` (SkyLight, закрытая).
    private static let setFront: SetFront? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(symbol, to: SetFront.self)
    }()

    /// `GetProcessForPID` (HIServices; устаревшая, но рабочая — через dlsym, без предупреждения сборки).
    private static let getProcess: GetProcess? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "GetProcessForPID") else { return nil }
        return unsafeBitCast(symbol, to: GetProcess.self)
    }()

    private static let userGenerated: UInt32 = 0x200

    static func isFront(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Возвращает путь для журнала: «уже», «обычная», «skylight», «НЕ удалось (…)».
    static func activate(pid: pid_t, mode: ActivationMode, timeout: TimeInterval = 0.08) async -> String {
        guard ScreenOutput.mayShow("Скрытый экран: активация программы") else { return "скрыто тестом" }
        if isFront(pid) { return "уже" }
        if mode != .skylight, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            if await waitFront(pid, timeout) { return "обычная" }
            if mode == .public { return "НЕ удалось (обычная)" }
        }
        guard let setFront, let getProcess else { return "НЕ удалось (нет SkyLight)" }
        var psn = ProcessSerialNumber()
        let status = withUnsafeMutableBytes(of: &psn) { getProcess(pid, $0.baseAddress!) }
        guard status == 0 else { return "НЕ удалось (GetProcessForPID \(status))" }
        let result = withUnsafeMutableBytes(of: &psn) { setFront($0.baseAddress!, 0, userGenerated) }
        if await waitFront(pid, 0.15) { return "skylight" }
        return "НЕ удалось (skylight \(result))"
    }

    private static func waitFront(_ pid: pid_t, _ seconds: TimeInterval) async -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        while !isFront(pid), ProcessInfo.processInfo.systemUptime - started < seconds {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return isFront(pid)
    }
}
