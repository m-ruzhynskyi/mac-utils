import AppKit
import CoreAudio
import Foundation

/// Чтение системы для «Перед звонком». Только чтение: ничего не пишет и не показывает системных диалогов.
package enum PreCallProbe {
    package static func dockAutohide() -> Bool? {
        guard let value = CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Уведомления программ по `com.apple.ncprefs`. Нет записи у программы — она не установлена или ещё не просила
    /// уведомлений: не считаем её источником. Нечитаемые данные — `.unknown`.
    package static func notifications(bundleIDs: [String]) -> PreCallRules.NotificationsState {
        guard let apps = CFPreferencesCopyAppValue("apps" as CFString, "com.apple.ncprefs" as CFString) as? [[String: Any]] else {
            return .unknown
        }
        var on: [String] = [], known = 0
        for id in bundleIDs {
            guard let entry = apps.first(where: { ($0["bundle-id"] as? String) == id }) else { continue }
            guard let enabled = PreCallRules.notificationsEnabled(flags: entry["flags"] as? Int) else { return .unknown }
            known += 1
            if enabled, !on.contains(displayName(id)) { on.append(displayName(id)) }
        }
        if known == 0 { return .unknown }
        return on.isEmpty ? .off(apps: []) : .on(apps: on)
    }

    private static func displayName(_ bundleID: String) -> String {
        HiddenScreenRules.defaultApps.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    /// Текущее устройство вывода: встроенное или внешнее, и воткнуты ли наушники в разъём.
    package static func outputKind() -> PreCallRules.OutputKind {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return .unknown }

        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let isBuiltIn: Bool? = AudioObjectGetPropertyData(device, &tAddress, 0, nil, &tSize, &transport) == noErr
            ? transport == kAudioDeviceTransportTypeBuiltIn : nil

        var source: UInt32 = 0
        var sSize = UInt32(MemoryLayout<UInt32>.size)
        var sAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        // 'hdpn' — наушники в разъёме, 'ispk' — динамики.
        let headphones = AudioObjectGetPropertyData(device, &sAddress, 0, nil, &sSize, &source) == noErr && source == 0x6864706E
        return PreCallRules.outputKind(isBuiltIn: isBuiltIn, dataSourceIsHeadphones: headphones)
    }

    /// Имя основного экрана — подсказка «показывайте экран …».
    @MainActor
    package static func mainDisplayName() -> String? { NSScreen.main?.localizedName }

    @MainActor
    package static func run(bundleIDs: [String] = HiddenScreenRules.defaultApps.map(\.bundleID)) -> [PreCallCheck] {
        PreCallRules.all(dockAutohide: dockAutohide(), notifications: notifications(bundleIDs: bundleIDs),
                         output: outputKind(), mainDisplayName: mainDisplayName())
    }
}
