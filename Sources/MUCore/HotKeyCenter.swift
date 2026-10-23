import Carbon.HIToolbox
import Foundation

/// Глобальные горячие клавиши через Carbon (не требуют «Универсального доступа»).
/// Функции просят своё сочетание по умолчанию; если пользователь переназначил его в настройках,
/// регистрируется выбранное (`resolver`, в приложении — `HotKeyRegistry.resolve`). Для каждого сочетания помнится, что просили
/// и удалось ли зарегистрировать — это показывают настройки и шпаргалка.
@MainActor
package final class HotKeyCenter: ObservableObject {
    package static let shared = HotKeyCenter()

    private struct Request {
        package var combo: LayoutHotKey
        package var handler: () -> Void
    }

    private var requests: [UInt32: Request] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    /// Пока в настройках записывается новое сочетание, старое не регистрируется.
    private var suspended: Set<UInt32> = []
    private var installed = false

    /// Зарегистрированные сейчас сочетания (фактические, после замены из настроек).
    /// Что на самом деле регистрировать под идентификатором (замены из настроек); подставляет приложение при запуске.
    package var resolver: (UInt32, LayoutHotKey) -> LayoutHotKey = { $1 }

    @Published package private(set) var active: [UInt32: LayoutHotKey] = [:]
    /// Не удалось зарегистрировать: сочетание занято системой или другой программой (код Carbon).
    @Published package private(set) var failures: [UInt32: OSStatus] = [:]

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKey)
            guard status == noErr else { return status }
            let id = hotKey.id
            MainActor.assumeIsolated {
                HotKeyCenter.shared.fire(id)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    package func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        let combo = LayoutHotKey(keyCode: keyCode, modifiers: modifiers)
        // Те же клавиши и уже зарегистрировано: только обновляем обработчик, Carbon не трогаем
        // (функции вызывают sync на каждую запись в UserDefaults).
        let unchanged = Self.isUnchanged(old: requests[id]?.combo, new: combo, registered: refs[id] != nil)
        requests[id] = Request(combo: combo, handler: handler)
        return unchanged ? true : apply(id)
    }

    /// Перерегистрировать не нужно: просили то же сочетание, и оно уже стоит.
    package nonisolated static func isUnchanged(old: LayoutHotKey?, new: LayoutHotKey, registered: Bool) -> Bool {
        registered && old == new
    }

    /// Пометка «приостановлено» (идёт запись в настройках) сохраняется: её снимает только `resume`.
    package func unregister(id: UInt32) {
        removeCarbon(id)
        requests[id] = nil
        setActive(id, nil)
        setFailure(id, nil)
    }

    package func isRegistered(id: UInt32) -> Bool { refs[id] != nil }

    /// Функция просила это сочетание (включена), даже если зарегистрировать его не удалось.
    package func isRequested(id: UInt32) -> Bool { requests[id] != nil }

    /// Временно снять сочетание (запись нового в настройках), не забывая, что функция его просила.
    package func suspend(id: UInt32) {
        suspended.insert(id)
        removeCarbon(id)
        setActive(id, nil)
    }

    package func resume(id: UInt32) {
        suspended.remove(id)
        apply(id)
    }

    /// Сочетание в настройках изменилось: перерегистрировать с новым значением, если функция включена.
    package func reapply(id: UInt32) {
        if requests[id] != nil { apply(id) }
    }

    @discardableResult
    private func apply(_ id: UInt32) -> Bool {
        guard let request = requests[id] else { return false }
        removeCarbon(id)
        guard !suspended.contains(id) else { return false }
        installIfNeeded()
        let combo = resolver(id, request.combo)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D555449), id: id) // 'MUTI'
        let status = RegisterEventHotKey(UInt32(combo.keyCode), UInt32(combo.modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.window.error("Горячая клавиша \(id) (\(combo.title, privacy: .public)) не зарегистрирована: \(status)")
            setActive(id, nil)
            setFailure(id, status == noErr ? -1 : status)
            return false
        }
        refs[id] = ref
        setActive(id, combo)
        setFailure(id, nil)
        return true
    }

    private func removeCarbon(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }

    // Публикуем только изменения: функции перерегистрируют сочетания на каждую запись в UserDefaults.
    private func setActive(_ id: UInt32, _ combo: LayoutHotKey?) {
        if active[id] != combo { active[id] = combo }
    }

    private func setFailure(_ id: UInt32, _ status: OSStatus?) {
        if failures[id] != status { failures[id] = status }
    }

    fileprivate func fire(_ id: UInt32) {
        guard refs[id] != nil else { return }
        requests[id]?.handler()
    }
}
