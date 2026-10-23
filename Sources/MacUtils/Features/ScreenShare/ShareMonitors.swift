import AppKit
import MUDesign

/// Монитор ведущего в сообщении `displays` (SHARE-PROTOCOL §4.1): номер, основной, пиксели, масштаб и место на схеме.
/// Имён устройств и ID здесь нет: номер `n` — всё, что знает зритель. Формат проверяет общая фикстура
/// relay/tests/fixtures/displays.json (ShareCompatTests, relay, Windows).
struct ShareDisplay: Equatable {
    let n: Int
    let primary: Bool
    let width: Int
    let height: Int
    let scale: Double
    /// Место в раскладке ведущего в логических единицах (Mac — точки, Windows — DIP), y вниз.
    let at: CGRect

    var percent: String { "\(Int((scale * 100).rounded())) %" }
    /// «Монитор 3 · 1920×1080 · 100 %».
    var title: String { "Монитор \(n) · \(width)×\(height) · \(percent)" }
    /// Для VoiceOver: «Монитор 2, основной, 3840 на 2160, 175 %, показывается сейчас».
    func accessibilityLabel(current: Int?) -> String {
        ["Монитор \(n)", primary ? "основной" : nil, "\(width) на \(height)", percent, n == current ? "показывается сейчас" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

enum ShareDisplays {
    static let maxCount = 8

    /// Экран Mac для списка: рамка Cocoa (y вверх от низа основного), пиксели кадра, масштаб.
    struct Screen {
        let id: CGDirectDisplayID
        let frame: CGRect
        let pixels: CGSize
        let scale: CGFloat
        let primary: Bool
    }

    /// Мониторы этого Mac сейчас.
    @MainActor static func screens() -> [Screen] {
        let main = NSScreen.screens.first?.displayID
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let scale = screen.backingScaleFactor
            let mode = CGDisplayCopyDisplayMode(id)
            let pixels = mode.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
                ?? CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
            return Screen(id: id, frame: screen.frame, pixels: pixels, scale: scale, primary: id == main)
        }
    }

    /// Нумерация одна на Mac и Windows: слева направо, затем сверху вниз, с 1. `id` остаётся внутри процесса.
    static func list(_ screens: [Screen]) -> [(display: ShareDisplay, id: CGDirectDisplayID)] {
        let top = screens.first(where: \.primary)?.frame.maxY ?? screens.map(\.frame.maxY).max() ?? 0
        let placed = screens.map { screen -> (Screen, CGRect) in
            // Cocoa (y вверх от низа основного) → y вниз от верха основного, как у Windows.
            (screen, CGRect(x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height))
        }
        let sorted = placed.sorted { $0.1.minX != $1.1.minX ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }
        return sorted.prefix(maxCount).enumerated().map { index, pair in
            let (screen, at) = pair
            let display = ShareDisplay(n: index + 1, primary: screen.primary,
                                       width: clampPixels(screen.pixels.width), height: clampPixels(screen.pixels.height),
                                       scale: (min(max(Double(screen.scale), 0.5), 4) * 100).rounded() / 100, at: at)
            return (display, screen.id)
        }
    }

    private static func clampPixels(_ value: CGFloat) -> Int { min(max(Int(value.rounded()), 1), 32768) }

    /// JSON `displays`; переключать нельзя (настройка, окно, нет текущего) — пустой список без `current`.
    /// `video` — как ведущий кодирует (hw / sw / jpeg): необязательное поле, старые зрители его не читают.
    static func message(rev: Int, list: [ShareDisplay], current: Int?, allowed: Bool, video: String? = nil) -> String {
        var object: [String: Any] = ["type": "displays", "v": 1, "rev": rev]
        if let video, ShareVideoMode.hostModes.contains(video) { object["video"] = video }
        if allowed, let current, list.contains(where: { $0.n == current }) {
            object["current"] = current
            object["list"] = list.prefix(maxCount).map { display -> [String: Any] in
                ["n": display.n, "primary": display.primary, "w": display.width, "h": display.height, "scale": display.scale,
                 "at": [display.at.minX, display.at.minY, display.at.width, display.at.height].map(Self.number)]
            }
        } else {
            object["list"] = [Any]()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Целые точки — целым числом (как у страницы), дробные — как есть.
    private static func number(_ value: CGFloat) -> Any {
        value == value.rounded() && abs(value) < 1e9 ? Int(value) as Any : Double(value) as Any
    }

    struct Parsed: Equatable {
        let rev: Int
        let current: Int?
        let list: [ShareDisplay]
    }

    /// `displays` от ведущего; незнакомая версия формата или мусор — nil (зритель игнорирует).
    static func parse(_ json: [String: Any]) -> Parsed? {
        guard json["type"] as? String == "displays", integer(json["v"]) == 1, let rev = integer(json["rev"]),
              let raw = json["list"] as? [Any] else { return nil }
        var list: [ShareDisplay] = []
        for item in raw.prefix(maxCount) {
            guard let item = item as? [String: Any], let n = integer(item["n"]), let w = integer(item["w"]), let h = integer(item["h"]),
                  let scale = item["scale"] as? Double, let at = item["at"] as? [Double], at.count == 4,
                  at.allSatisfy(\.isFinite), at[2] > 0, at[3] > 0, !list.contains(where: { $0.n == n }) else { continue }
            list.append(ShareDisplay(n: n, primary: (item["primary"] as? Bool) ?? false, width: w, height: h, scale: (scale * 100).rounded() / 100,
                                     at: CGRect(x: at[0], y: at[1], width: at[2], height: at[3])))
        }
        let current = integer(json["current"]).flatMap { n in list.contains { $0.n == n } ? n : nil }
        return Parsed(rev: rev, current: current, list: current == nil ? [] : list)
    }

    /// Целое из JSON: NSNumber с булевым значением (true/false) — не число.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double == double.rounded() && abs(double) <= Double(Int32.max) ? Int(double) : nil
    }

    /// Ревизия списка: растёт, только когда меняется сам список (состав, размеры, масштаб, раскладка), а не текущий.
    struct Revision {
        private(set) var value = 0
        private var last: [ShareDisplay]?

        mutating func update(_ list: [ShareDisplay]) -> Int {
            if list != last {
                last = list
                value = (value + 1) % Int(Int32.max)
            }
            return value
        }
    }
}

/// Правило ведущего на `switch-request` — одно на Mac и странице relay (`switchDecision`).
enum ShareMonitorSwitch {
    static let gap: TimeInterval = 2
    static let wait: TimeInterval = 8

    enum Decision: String { case off, stale, ok, busy, change }

    struct HostState {
        var allowed: Bool
        /// Транслируется монитор целиком (не окно и не программа).
        var screen: Bool
        var rev: Int
        var list: [ShareDisplay]
        var current: Int?
        var switching: Bool
        var lastSwitchAt: Date?
    }

    /// 1. выключено или не экран → off; 2. ревизия или номер не те → stale; 3. уже он → ok;
    /// 4. идёт переключение или прошло меньше 2 с → busy; 5. переключить.
    static func decide(_ state: HostState, display: Int, rev: Int, now: Date) -> Decision {
        guard state.allowed, state.screen, !state.list.isEmpty else { return .off }
        guard rev == state.rev, state.list.contains(where: { $0.n == display }) else { return .stale }
        if display == state.current { return .ok }
        if state.switching || state.lastSwitchAt.map({ now.timeIntervalSince($0) < gap }) == true { return .busy }
        return .change
    }

    /// Чем закончилось разрешённое переключение: не вышло — failed; вышло, но настройку за это время выключили — off
    /// (вслед уйдёт пустой список); иначе ok.
    static func result(switched: Bool, allowed: Bool) -> String {
        guard switched else { return "failed" }
        return allowed ? "ok" : "off"
    }

    /// Свежий список на устаревший или запрещённый запрос — не чаще раза в секунду.
    static let reannounceInterval: TimeInterval = 1
    static func shouldReannounce(last: Date?, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) >= reannounceInterval } ?? true
    }

    /// Окно (метки, уведомление) исключено из захвата, только если оно есть среди окон, которые фильтр исключает.
    static func windowExcluded(_ number: Int?, from windows: [Int]) -> Bool {
        guard let number else { return false }
        return windows.contains(number)
    }

    struct Request: Equatable {
        let display: Int
        let rev: Int
        let from: String
        let name: String
    }

    /// `switch-request`, как его пересобрал relay (`from`, `name` — от relay).
    static func parseRequest(_ json: [String: Any]) -> Request? {
        guard json["type"] as? String == "switch-request", let display = ShareDisplays.integer(json["display"]),
              let rev = ShareDisplays.integer(json["rev"]) else { return nil }
        return Request(display: display, rev: rev, from: json["from"] as? String ?? "",
                       name: String((json["name"] as? String ?? "").prefix(60)))
    }

    static func requestMessage(display: Int, rev: Int) -> String {
        #"{"type":"switch-request","display":\#(display),"rev":\#(rev)}"#
    }

    /// Ответ одному зрителю: ok, off, stale, busy или failed; после ok следом идёт `displays`.
    static func resultMessage(to viewer: String, display: Int, result: String) -> String? {
        let object: [String: Any] = ["type": "switch-result", "to": viewer, "display": display, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Зритель: мониторы ведущего и запрос в пути (как `monitorViewer` на странице relay).
struct ShareMonitorPicker: Equatable {
    private(set) var list: [ShareDisplay] = []
    private(set) var current: Int?
    private(set) var rev = 0
    private(set) var pending: Int?
    private var pendingAt: Date?
    private var known = false

    /// switched — показывается другой монитор (метки — заново); gone — список пропал; done — запрос в пути завершён.
    struct Change: Equatable {
        var switched = false
        var gone = false
        var done = false
    }

    mutating func apply(_ parsed: ShareDisplays.Parsed) -> Change {
        let had = !list.isEmpty, before = current, first = !known
        known = true
        rev = parsed.rev
        list = parsed.list
        current = parsed.current
        var change = Change()
        change.switched = !first && had && current != nil && current != before
        change.gone = had && list.isEmpty
        if let pending, current == pending || !list.contains(where: { $0.n == pending }) {
            self.pending = nil
            pendingAt = nil
            change.done = true
        }
        return change
    }

    /// Клик или клавиша: сообщение для relay или nil (нет такого, уже показывается, запрос уже в пути).
    mutating func request(_ n: Int, now: Date) -> String? {
        guard pending == nil, n != current, list.contains(where: { $0.n == n }) else { return nil }
        pending = n
        pendingAt = now
        return ShareMonitorSwitch.requestMessage(display: n, rev: rev)
    }

    enum Notice: Equatable { case off, busy, failed }

    /// `switch-result` → что сказать зрителю (nil — ничего: ok ждёт `displays`, stale — свежий список уже в пути).
    mutating func result(display: Int, result: String) -> Notice? {
        guard let pending, display == pending else { return nil }
        if result == "ok" {
            if current == pending { self.pending = nil; pendingAt = nil }
            return nil
        }
        self.pending = nil
        pendingAt = nil
        switch result {
        case "off": return .off
        case "busy": return .busy
        case "failed": return .failed
        default: return nil
        }
    }

    /// Ответа нет 8 с — запрос снимается.
    mutating func expired(now: Date) -> Bool {
        guard pending != nil, let pendingAt, now.timeIntervalSince(pendingAt) >= ShareMonitorSwitch.wait else { return false }
        pending = nil
        self.pendingAt = nil
        return true
    }

    /// Клавиши 1…9 в окне просмотра: номер монитора, если он есть в списке.
    func monitor(forKey characters: String) -> Int? {
        guard characters.count == 1, let n = Int(characters), (1...9).contains(n), list.contains(where: { $0.n == n }) else { return nil }
        return n
    }
}

/// Подпись режима видео у зрителя (как у страницы, `videoModeLabel`): тип кадров зритель знает сам (H.264 или картинки
/// JPEG), аппаратно ли кодирует ведущий — из поля `video` сообщения `displays`.
enum ShareVideoMode {
    static let hostModes: Set<String> = ["hw", "sw", "jpeg"]

    /// `video` из `displays`; нет поля (старый ведущий, старый relay) или чужое значение — nil.
    static func host(from json: [String: Any]) -> String? {
        (json["video"] as? String).flatMap { hostModes.contains($0) ? $0 : nil }
    }

    /// `marks: "video"` из `displays`: метки поверх экрана ведущего попадают в видео (Windows без подтверждённого
    /// исключения окна из захвата). Нет поля или другое значение — false: зритель рисует метки сам, как раньше.
    static func marksInVideo(from json: [String: Any]) -> Bool { json["marks"] as? String == "video" }

    /// JPEG после H.264 — мост ведущего (кодер пересоздаётся), только если H.264 не было дольше `bridgeGap`. Иначе это кадры
    /// для старых зрителей, которые ведущий Mac шлёт параллельно (раз в 0,25 с): их не показываем, чтобы картинка и подпись
    /// не мигали. Как у страницы (`jpegIsBridge`).
    static let bridgeGap: TimeInterval = 0.7
    static func jpegIsBridge(now: Date, lastVideo: Date?) -> Bool {
        guard let lastVideo else { return true }
        return now.timeIntervalSince(lastVideo) > bridgeGap
    }

    /// pictures: true — приходят картинки, false — видео H.264, nil — кадров ещё нет.
    static func label(pictures: Bool?, host: String?) -> String? {
        if pictures == true || (pictures == nil && host == "jpeg") { return "Картинки" }
        if pictures == nil && host == nil { return nil }
        switch host {
        case "hw": return "Видео · видеокарта"
        case "sw": return "Видео · без видеокарты"
        default: return "Видео"
        }
    }
}
