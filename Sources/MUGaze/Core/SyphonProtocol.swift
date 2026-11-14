import Foundation

/// Протокол Syphon (Syphon-Framework, BSD-2-Clause) — то, что нужно серверу, чтобы его видел «Syphon Client» в OBS.
/// Константы — из SyphonPrivate.h / .m. Своя реализация: Syphon.framework не собирается в SwiftPM.
package enum SyphonProtocol {
    package static let identifier = "info.v002.Syphon"
    package static let announceRequest = "info.v002.Syphon.ServerAnnounceRequest"
    package static let announce = "info.v002.Syphon.ServerAnnounce"
    package static let retire = "info.v002.Syphon.ServerRetire"
    package static let update = "info.v002.Syphon.ServerUpdate"

    package static let dictionaryVersionKey = "SyphonServerDescriptionDictionaryVersionKey"
    package static let uuidKey = "SyphonServerDescriptionUUIDKey"
    package static let nameKey = "SyphonServerDescriptionNameKey"
    package static let appNameKey = "SyphonServerDescriptionAppNameKey"
    package static let surfacesKey = "SyphonServerDescriptionSurfacesKey"
    package static let surfaceType = "SyphonSurfaceType"
    package static let surfaceTypeIOSurface = "SyphonSurfaceTypeIOSurface"

    /// Клиент → сервер (данные — UUID клиента, NSString).
    package enum ToServer: Int32 {
        case addClientForInfo = 0, addClientForFrames = 1, removeClientForInfo = 2, removeClientForFrames = 3
    }

    /// Сервер → клиент.
    package enum ToClient: Int32 {
        case updateServerName = 0, newFrame = 1, updateSurfaceID = 2, retireServer = 3
    }

    /// Имя порта сервера: «info.v002.Syphon.<UUID>».
    package static func makeServerUUID(_ uuid: UUID = UUID()) -> String { "\(identifier).\(uuid.uuidString)" }

    /// Описание сервера для объявлений (DictionaryVersion 0, одна поверхность IOSurface — это проверяет OBS).
    package static func description(uuid: String, name: String, appName: String) -> [String: Any] {
        [
            dictionaryVersionKey: NSNumber(value: UInt32(0)),
            nameKey: name,
            uuidKey: uuid,
            appNameKey: appName,
            surfacesKey: [[surfaceType: surfaceTypeIOSurface]],
        ]
    }

    /// Данные сообщения: NSKeyedArchiver с безопасным кодированием, как в SyphonCFMessageSender.
    package static func encode(_ payload: (any NSObject & NSSecureCoding)?) -> Data? {
        guard let payload else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: payload, requiringSecureCoding: true)
    }

    /// UUID клиента из сообщения клиента.
    package static func decodeClientUUID(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: data)) as String?
    }

    /// Номер IOSurface (так его шлёт сервер в updateSurfaceID).
    package static func decodeSurfaceID(_ data: Data?) -> UInt32? {
        guard let data, !data.isEmpty else { return nil }
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSNumber.self, from: data))?.uint32Value
    }
}

/// Кто подписан на сервер: «информационные» клиенты получают номер поверхности и уход сервера, «кадровые» — новые кадры.
/// Чистое состояние — в тестах; сокеты держит `SyphonServer`.
package struct SyphonClientRegistry: Equatable, Sendable {
    package private(set) var info: Set<String> = []
    package private(set) var frames: Set<String> = []

    package init() {}

    package enum Reply: Equatable, Sendable {
        /// Отправить клиенту номер поверхности (если она уже есть).
        case sendSurfaceID(to: String)
        /// Отправить клиенту «новый кадр», чтобы он сразу забрал текущий.
        case sendNewFrame(to: String)
    }

    /// Обработать сообщение клиента. `hasSurface` — есть ли уже кадр.
    package mutating func handle(_ message: SyphonProtocol.ToServer, client: String, hasSurface: Bool) -> [Reply] {
        switch message {
        case .addClientForInfo:
            info.insert(client)
            return hasSurface ? [.sendSurfaceID(to: client)] : []
        case .addClientForFrames:
            frames.insert(client)
            return hasSurface ? [.sendNewFrame(to: client)] : []
        case .removeClientForInfo:
            info.remove(client)
        case .removeClientForFrames:
            frames.remove(client)
        }
        return []
    }

    /// Клиент пропал (порт недействителен) — убрать отовсюду.
    package mutating func drop(_ client: String) { info.remove(client); frames.remove(client) }

    package mutating func removeAll() { info.removeAll(); frames.removeAll() }

    /// Есть ли кто-то, кто забирает кадры (для строки «OBS получает картинку»).
    package var hasFrameClients: Bool { !frames.isEmpty }
}
