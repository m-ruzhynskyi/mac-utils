import AppKit
import CoreText
import os
import MUDesign

/// Шрифты Microsoft для «Документа»: те же файлы, что у Word, — те же ширины знаков и переносы строк.
/// Есть Word — нужные семейства из его папки шрифтов регистрируются только для процесса Mac Utils
/// (`CTFontManagerRegisterFontURLs`, `.process`): файлы только читаются, никуда не копируются, в системе не ставятся.
/// Нет Word — метрически совместимые замены из ресурсов приложения (Carlito вместо Calibri, Caladea вместо Cambria;
/// таблица — `FontSubstitution.twins`). Регистрируются только семейства документа, которых нет в macOS.
@MainActor
package enum WordFonts {
    /// Папки шрифтов Word: в бандле приложения, где бы оно ни стояло.
    package static var folders: [URL] = defaultFolders()

    /// Замены из ресурсов приложения (`Resources/Fonts`, SIL OFL 1.1).
    package static let twinFiles = ["Carlito-Regular.ttf", "Carlito-Bold.ttf", "Carlito-Italic.ttf", "Carlito-BoldItalic.ttf",
                            "Caladea-Regular.ttf", "Caladea-Bold.ttf", "Caladea-Italic.ttf", "Caladea-BoldItalic.ttf"]

    private static var index: [String: [URL]]?
    private static var handled: Set<String> = []
    private static var twinsRegistered = false
    private static let log = Logger(subsystem: "com.mruzhynskyi.macutils", category: "document")

    /// Подключить шрифты для семейств документа (имена из `\fonttbl`). Повторный вызов с теми же именами ничего не делает.
    /// Возвращает семейства, которые зарегистрированы этим вызовом.
    @discardableResult
    package static func prepare(_ names: some Sequence<String>) -> [String] {
        let wanted = Set(names.map(FontSubstitution.baseName)).subtracting(handled).filter { !$0.isEmpty }
        handled.formUnion(wanted)
        let missing = wanted.filter { !FontCatalog.isInstalled($0) }
        guard !missing.isEmpty else { return [] }
        let index = self.index ?? buildIndex(folders)
        self.index = index
        var urls: [URL] = []
        var families: [String] = []
        for family in missing.sorted() {
            guard let files = index[family] else { continue }
            urls += files
            families.append(family)
        }
        if !urls.isEmpty { register(Array(Set(urls)).sorted { $0.path < $1.path }) }
        // Чего нет и у Word (или нет самого Word) — показ метрически совместимой заменой, если она известна.
        if missing.contains(where: { index[$0] == nil && FontSubstitution.twins[$0] != nil }) { registerTwins() }
        FontCatalog.refresh()
        let registered = families.filter(FontCatalog.isInstalled)
        if !registered.isEmpty { log.info("Шрифты Word для процесса: \(registered.count, privacy: .public) семейств") }
        return registered
    }

    /// Семейство → файлы во всех папках Word (по таблице имён самих файлов, а не по именам файлов).
    package static func buildIndex(_ folders: [URL]) -> [String: [URL]] {
        var result: [String: [URL]] = [:]
        let manager = FileManager.default
        for folder in folders {
            guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for url in files where ["ttf", "ttc", "otf"].contains(url.pathExtension.lowercased()) {
                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
                for descriptor in descriptors {
                    guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else { continue }
                    if result[family]?.contains(url) != true { result[family, default: []].append(url) }
                }
            }
        }
        return result
    }

    private static func register(_ urls: [URL]) {
        var failed = 0
        for url in urls {
            var error: Unmanaged<CFError>?
            // Уже зарегистрированный (повторное открытие) — не ошибка.
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
               let error = error?.takeRetainedValue(), CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue {
                failed += 1
            }
        }
        if failed > 0 { log.error("Шрифты Word: не зарегистрировано \(failed, privacy: .public) файлов — показ заменой") }
    }

    private static func registerTwins() {
        guard !twinsRegistered else { return }
        twinsRegistered = true
        let urls = twinFiles.compactMap { name in
            DSFonts.searchFolders.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        register(urls)
    }

    private static func defaultFolders() -> [URL] {
        var apps = [URL(fileURLWithPath: "/Applications/Microsoft Word.app")]
        if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Word"), !apps.contains(found) {
            apps.append(found)
        }
        return apps.map { $0.appendingPathComponent("Contents/Resources/DFonts") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
