import AVFoundation
import Foundation
import UniformTypeIdentifiers
import MUCore
import MUAudio

/// Настройки плеера поверх `UserDefaults` (ключи — в `Pref`).
enum PlayerPrefs {
    private static var defaults: UserDefaults { .standard }

    static var rememberPosition: Bool { defaults.bool(forKey: Pref.playerRememberPosition) }
    static var keepAwake: Bool { defaults.bool(forKey: Pref.playerKeepAwake) }
    static var keepPitch: Bool { defaults.bool(forKey: Pref.playerKeepPitch) }
    static var subtitlesNearby: Bool { defaults.bool(forKey: Pref.playerSubtitlesNearby) }
    static var skipAutomatically: Bool { defaults.bool(forKey: Pref.playerSkipAuto) }
    static var nextEpisode: Bool { defaults.bool(forKey: Pref.playerNextEpisode) }
    static var opensShots: Bool { defaults.bool(forKey: Pref.playerOpensShots) }

    static let seekSteps: [Double] = [5, 10, 30]

    /// Шаг ← → (5, 10 или 30 с).
    static var seekStep: Double {
        let value = defaults.double(forKey: Pref.playerSeekStep)
        return seekSteps.contains(value) ? value : 5
    }

    static var volume: Float {
        get {
            guard defaults.object(forKey: Pref.playerVolume) != nil else { return 1 }
            return Float(min(max(defaults.double(forKey: Pref.playerVolume), 0), 1))
        }
        set { defaults.set(Double(newValue), forKey: Pref.playerVolume) }
    }

    /// Размер субтитров: 0 — S, 1 — M, 2 — L.
    static var subtitleSize: Int { min(max(defaults.integer(forKey: Pref.playerSubtitleSize), 0), 2) }
    static var subtitleBackground: Bool { defaults.bool(forKey: Pref.playerSubtitleBackground) }

    static var subtitleLanguage: String? { defaults.string(forKey: Pref.playerSubtitleLanguage) }
    static var audioLanguage: String? { defaults.string(forKey: Pref.playerAudioLanguage) }

    static var skipHiddenFolders: Set<String> { Set(defaults.stringArray(forKey: Pref.playerSkipHiddenFolders) ?? []) }

    static func hideSkip(inFolder path: String) {
        var folders = skipHiddenFolders
        folders.insert(path)
        defaults.set(folders.sorted(), forKey: Pref.playerSkipHiddenFolders)
    }
}

/// Скорость: 0,25–4× с шагом 0,25 (`[` и `]`).
enum PlaybackRate {
    static let range: ClosedRange<Float> = 0.25...4
    static let step: Float = 0.25
    static let presets: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    static func clamp(_ rate: Float) -> Float {
        min(max((rate / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    static func stepped(_ rate: Float, by direction: Int) -> Float {
        clamp(rate + Float(direction) * step)
    }

    /// «1×», «1,25×», «0,5×».
    static func title(_ rate: Float) -> String {
        let rounded = (rate * 100).rounded() / 100
        var text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
        text = text.replacingOccurrences(of: ".", with: ",")
        return text + "×"
    }
}

/// Время на шкале: «4:05», «23:10», «1:02:03»; оставшееся — «−25:00».
enum PlayerFormat {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func remaining(_ current: Double, of duration: Double) -> String {
        "−" + time(max(0, duration.rounded(.down) - current.rounded(.down)))
    }

    /// «00:23:10:05» — с номером кадра в секунде.
    static func timecode(_ seconds: Double, fps: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00:00:00" }
        let fps = fps > 0 ? fps : 25
        let total = Int(seconds.rounded(.down))
        let frame = Int(((seconds - Double(total)) * fps).rounded(.down))
        return String(format: "%02d:%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60, frame)
    }

    /// «33 365» — с пробелом-разделителем тысяч, как в макете.
    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{2009}"
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// Что умеет открыть плеер: всё, что играет AVFoundation. MKV, WebM, AVI и прочие — экран «формат не поддерживается».
enum PlayerMedia {
    /// Контейнеры, которые AVFoundation не открывает (вторая версия — через ffmpeg).
    static let unsupportedExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "asf", "ogv", "ogg", "ogm", "rm", "rmvb", "divx", "vob"]

    /// «Открыть с помощью» и панель: эти расширения объявлены в `CFBundleDocumentTypes` с рангом Alternate.
    static let openWithExtensions = ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac"]

    static func isUnsupported(_ url: URL) -> Bool { unsupportedExtensions.contains(url.pathExtension.lowercased()) }

    /// Видео или звук (по типу файла), в том числе то, что откроется только во второй версии.
    static func isMedia(_ url: URL) -> Bool {
        if isUnsupported(url) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audiovisualContent)
    }

    static func isVideo(_ url: URL) -> Bool {
        if isUnsupported(url) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie)
    }

    static func isSubtitle(_ url: URL) -> Bool { SubtitleParser.extensions.contains(url.pathExtension.lowercased()) }

    /// Файлы и папки → медиафайлы по порядку («Серия 2» раньше «Серия 10»). Папки — без вложенных.
    static func expand(_ urls: [URL], manager: FileManager = .default) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            guard isDirectory.boolValue else { return isMedia(url) ? [url] : [] }
            let children = (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return children.filter(isMedia).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
    }

    /// Название контейнера для экрана «не поддерживается»: «MKV», «WebM», «AVI».
    static func formatName(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["webm": "WebM", "ogv": "OGV", "divx": "DivX", "rmvb": "RMVB"][ext] ?? ext.uppercased()
    }
}

/// Строка под именем файла: «H.264 · 1920 × 1080 · 24 к/с · AAC 5.1».
enum CodecDescription {
    static func video(_ subtype: FourCharCode) -> String {
        switch subtype {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha, 0x68657631: return "HEVC"   // hvc1, hev1
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            return "ProRes"
        case kCMVideoCodecType_MPEG4Video: return "MPEG-4"
        case kCMVideoCodecType_JPEG, kCMVideoCodecType_JPEG_OpenDML: return "Motion JPEG"
        case 0x61763031: return "AV1"   // av01
        case kCMVideoCodecType_MPEG2Video: return "MPEG-2"
        default: return fourCC(subtype)
        }
    }

    static func audio(_ subtype: FourCharCode) -> String {
        switch subtype {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD: return "AAC"
        case kAudioFormatAC3, 0x61632D33: return "AC-3"
        case kAudioFormatEnhancedAC3: return "E-AC-3"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatOpus: return "Opus"
        default: return fourCC(subtype)
        }
    }

    static func channels(_ count: UInt32) -> String? {
        switch count {
        case 0: return nil
        case 1: return "моно"
        case 2: return "стерео"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count) кан."
        }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [code >> 24, code >> 16, code >> 8, code].map { UInt8($0 & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// «24 к/с», «29,97 к/с».
    static func frameRate(_ fps: Float) -> String? {
        guard fps > 0 else { return nil }
        let rounded = (fps * 100).rounded() / 100
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.2f", rounded).replacingOccurrences(of: ".", with: ",")
        return text + " к/с"
    }
}

/// Номер серии в имени файла: «s01e03», «S01E03», «1x03», «Серия 12», «Episode 5», «ep05», «3 серия».
/// Плейлист и заголовок сокращают имя так, чтобы номер оставался виден: иначе серии неразличимы.
enum EpisodeName {
    struct Parts: Equatable {
        let before: String
        let marker: String
        let after: String
    }

    private static let patterns: [NSRegularExpression] = [
        #"(?<![\p{L}\d])s\d{1,2}[ ._-]?e\d{1,4}(?!\d)"#,
        #"(?<![\p{L}\d])\d{1,2}x\d{2,3}(?!\d)"#,
        #"(?<!\p{L})(?:серия|эпизод|episode|ep)[ ._-]*\d{1,4}(?!\d)"#,
        #"(?<![\p{L}\d])\d{1,4}[ ._-]*(?:серия|эпизод)(?!\p{L})"#,
        #"(?<![\p{L}\d])e\d{2,4}(?!\d)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Имя, разрезанное вокруг номера серии; nil — номера нет.
    static func split(_ name: String) -> Parts? {
        let range = NSRange(name.startIndex..., in: name)
        for pattern in patterns {
            guard let match = pattern.firstMatch(in: name, range: range), let found = Range(match.range, in: name) else { continue }
            return Parts(before: String(name[..<found.lowerBound]), marker: String(name[found]), after: String(name[found.upperBound...]))
        }
        return nil
    }
}
