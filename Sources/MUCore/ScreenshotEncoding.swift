import AppKit

/// Кодирование и запись снимков без обращения к главному потоку и без перезаписи чужих файлов.
package enum ScreenshotEncoding {
    /// PNG из кадра. Для кадра 5K это сотни миллисекунд: вызывать вне главного потока.
    package static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    package static func tiff(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).tiffRepresentation
    }

    /// «Снимок 12.00.00.png» → «Снимок 12.00.00 (2).png» → «… (3).png» (как у файлов «Загрузок»).
    package static func numberedName(_ name: String, index: Int) -> String {
        guard index > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
    }

    /// Пишет файл, не затирая существующий: занятое имя получает номер. Занятость проверяет сама запись
    /// (`.withoutOverwriting`), поэтому два снимка в одну секунду, в том числе из разных потоков, не перезапишут друг друга.
    /// Жёсткая ссылка `from` → `to`: 0 или `errno`. Не заменяет существующий файл (EEXIST).
    package typealias Linker = (_ from: String, _ to: String) -> Int32

    package static let systemLinker: Linker = { from, to in link(from, to) == 0 ? 0 : errno }

    /// Ошибки «на этом томе жёстких ссылок нет» (exFAT/FAT, SMB, часть сетевых дисков): тогда пишем напрямую.
    package static let noHardLinks: Set<Int32> = [ENOTSUP, EPERM, EXDEV, EMLINK, ENOSYS, EACCES]

    package static func write(_ data: Data, to url: URL, limit: Int = 1000, linker: Linker = systemLinker) throws -> URL {
        let folder = url.deletingLastPathComponent()
        // Основной путь: целиком во временный скрытый файл, потом `link` под настоящим именем. `link` не заменяет
        // существующий файл (EEXIST), а падение посреди записи не оставляет обрезанный PNG под видом снимка.
        let temp = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .withoutOverwriting)
        defer { unlink(temp.path) }
        for index in 1...limit {
            let candidate = folder.appendingPathComponent(numberedName(url.lastPathComponent, index: index))
            let code = linker(temp.path, candidate.path)
            if code == 0 { return candidate }
            if code == EEXIST { continue }
            guard noHardLinks.contains(code) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: candidate.path])
            }
            // Запасной путь для томов без жёстких ссылок: прямая запись, которая тоже не заменяет существующий файл
            // (`O_EXCL` внутри `.withoutOverwriting`). Атомарность относительно существующих имён сохраняется;
            // обрезок при падении посреди записи на таком томе возможен, но снимок всё же сохраняется.
            return try writeDirect(data, folder: folder, name: url.lastPathComponent, from: index, limit: limit)
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
    }

    private static func writeDirect(_ data: Data, folder: URL, name: String, from first: Int, limit: Int) throws -> URL {
        for index in first...limit {
            let candidate = folder.appendingPathComponent(numberedName(name, index: index))
            do {
                try data.write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folder.appendingPathComponent(name).path])
    }
}

/// TIFF для буфера обмена кодируется только тогда, когда его кто-то попросил (несжатый кадр 5K — десятки мегабайт).
package final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let image: CGImage
    /// Вызывается, когда буфер обмена больше не нуждается в провайдере (скопировано другое): можно освободить кадр.
    package var onFinish: (() -> Void)?
    package init(_ image: CGImage) { self.image = image }

    package func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) { onFinish?() }

    package func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let data = ScreenshotEncoding.tiff(image) else { return }
        item.setData(data, forType: .tiff)
    }
}


/// Очерёдность копирования в буфер обмена. Кодирование идёт в фоне и заканчивается в произвольном порядке, а в буфере
/// должен оказаться снимок, который пользователь скопировал **последним**.
package struct ClipboardTickets {
    package init() {
    }

    private var issued = 0

    /// Выдаётся на главном потоке в момент команды «копировать».
    package mutating func next() -> Int {
        issued += 1
        return issued
    }

    /// Можно ли класть результат в буфер: после этого билета новых копирований не было.
    package func isLatest(_ ticket: Int) -> Bool { ticket == issued }
}
