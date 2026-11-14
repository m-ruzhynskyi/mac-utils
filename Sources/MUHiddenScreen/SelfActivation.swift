import AppKit
import MUCore

/// Сделать Mac Utils активной, а зеркало — ключевым окном и первым ответчиком.
@MainActor
enum SelfActivation {
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias GetProcess = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    /// `_SLPSSetFrontProcessWithOptions(psn, windowID, kCPSUserGenerated)` из SkyLight (закрытая).
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

    /// Возвращает, каким путём получилось (для журнала): «уже», «обычная», «skylight», «НЕ удалось».
    static func activate(window: NSWindow?, firstResponder: NSResponder?, mode: ActivationMode) async -> String {
        guard ScreenOutput.mayShow("Скрытый экран: активация Mac Utils") else { return "скрыто тестом" }
        defer {
            window?.makeKey()
            if let firstResponder { window?.makeFirstResponder(firstResponder) }
        }
        if NSApp.isActive { return "уже" }
        if mode != .skylight {
            ScreenOutput.activateApp(ignoringOtherApps: true)
            if await waitActive(0.08) { return "обычная" }
            if mode == .public { return "НЕ удалось (обычная)" }
        }
        guard let setFront, let getProcess else { return "НЕ удалось (нет SkyLight)" }
        var psn = ProcessSerialNumber()
        let status = withUnsafeMutableBytes(of: &psn) { getProcess(getpid(), $0.baseAddress!) }
        guard status == 0 else { return "НЕ удалось (GetProcessForPID \(status))" }
        let windowID = UInt32(window?.windowNumber ?? 0)
        let result = withUnsafeMutableBytes(of: &psn) { setFront($0.baseAddress!, windowID, userGenerated) }
        if await waitActive(0.15) { return "skylight" }
        return "НЕ удалось (skylight \(result))"
    }

    private static func waitActive(_ seconds: TimeInterval) async -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        while !NSApp.isActive, ProcessInfo.processInfo.systemUptime - started < seconds {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return NSApp.isActive
    }
}
