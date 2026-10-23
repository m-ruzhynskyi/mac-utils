import CryptoKit
import Foundation

/// Построчный разбор вывода помощника: данные приходят кусками, строка может быть рассечена посередине.
/// Строка без перевода, выросшая сверх `maxLength` (мусор), отбрасывается целиком вместе с хвостом до ближайшего `\n`.
package struct LineBuffer {
    package static let defaultMaxLength = 16 << 20

    private var buffer = Data()
    private var discarding = false
    package let maxLength: Int

    package init(maxLength: Int = LineBuffer.defaultMaxLength) { self.maxLength = maxLength }

    package var pendingCount: Int { buffer.count }

    package mutating func reset() {
        buffer = Data()
        discarding = false
    }

    /// Добавляет данные и возвращает все законченные строки (без `\n`, пустые пропускаются).
    package mutating func feed(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var rest = data[...]
        while !rest.isEmpty {
            guard let newline = rest.firstIndex(of: 0x0A) else {
                if !discarding {
                    buffer.append(rest)
                    if buffer.count > maxLength {
                        buffer = Data()
                        discarding = true
                    }
                }
                break
            }
            if discarding {
                discarding = false
            } else {
                buffer.append(rest[rest.startIndex..<newline])
                if buffer.count <= maxLength {
                    var line = buffer
                    if line.last == 0x0D { line.removeLast() }
                    if !line.isEmpty { lines.append(line) }
                }
            }
            buffer = Data()
            rest = rest[rest.index(after: newline)...]
        }
        return lines
    }
}

/// Обложка сравнивается по хешу данных, а не по объекту NSImage (новый объект на каждое событие помощника).
package enum ArtworkFingerprint {
    package static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Нужно ли сохранять обложку на диск: только если её содержимое изменилось.
    package static func shouldStore(newHash: String, lastStoredHash: String?) -> Bool {
        newHash != lastStoredHash
    }
}
