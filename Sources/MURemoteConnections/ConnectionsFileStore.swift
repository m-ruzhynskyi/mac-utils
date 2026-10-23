import AppKit
import Foundation

public enum ConnectionsFileState: Equatable, Sendable {
    case noFile
    case loading
    case ready
    case unavailable
    /// Облачный файл ещё скачивается: показываем «Файл ещё скачивается…» и повторяем.
    case cloudNotDownloaded
    case failed(ConnectionsError)
}

/// Файл подключений: путь, чтение, наблюдение за изменениями, повтор через 2 с.
/// В памяти — записи без паролей; пароль читается отдельно (`password(for:)`) в момент подключения.
@MainActor
public final class ConnectionsFileStore {
    public typealias Reader = @Sendable (URL, String?) throws -> ConnectionsSnapshot

    public private(set) var state: ConnectionsFileState = .noFile
    public private(set) var snapshot = ConnectionsSnapshot()
    /// Вызывается на главном потоке после каждого изменения состояния или списка.
    public var onChange: (() -> Void)?

    /// Сколько раз повторять «файл занят» (Excel сохраняет) и пропажу файла при атомарной замене.
    public static let busyRetries = 3
    /// Облако: 15 повторов по 2 с ≈ 30 с, потом «недоступен».
    public static let cloudRetries = 15

    private let settings: ConnectionsSettingsStore
    private let logger: RemoteLogger?
    private let reader: Reader
    private let retryDelay: TimeInterval
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "mu.remote.connections.read", qos: .utility)
    private var generation = 0
    private var attempt = 0
    private var retryWork: DispatchWorkItem?
    private var reloadWork: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var mountObserver: NSObjectProtocol?

    public init(settings: ConnectionsSettingsStore, logger: RemoteLogger? = nil,
                retryDelay: TimeInterval = 2, debounce: TimeInterval = 0.5,
                reader: @escaping Reader = { try ConnectionsFileStore.read(url: $0, sheet: $1) }) {
        self.settings = settings
        self.logger = logger
        self.reader = reader
        self.retryDelay = retryDelay
        self.debounce = debounce
    }

    deinit {
        watcher?.cancel()
        if let o = mountObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    public var fileURL: URL? { settings.filePath.map { URL(fileURLWithPath: $0) } }
    public var sheetName: String? { settings.sheetName }

    public func start() {
        if mountObserver == nil {
            mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didMountNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state == .unavailable else { return }
                    self.reload()
                }
            }
        }
        reload()
    }

    public func stop() {
        generation += 1
        retryWork?.cancel(); reloadWork?.cancel()
        unwatch()
        if let o = mountObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); mountObserver = nil }
    }

    public func setFile(_ url: URL?, sheet: String? = nil) {
        settings.filePath = url?.path
        settings.sheetName = sheet
        unwatch()
        snapshot = ConnectionsSnapshot()
        state = .noFile
        reload()
    }

    public func setSheet(_ name: String?) {
        settings.sheetName = name
        reload()
    }

    /// «Перечитать» и реакция на изменение файла.
    public func reload() {
        retryWork?.cancel()
        attempt = 0
        load()
    }

    // MARK: Чтение

    private func load() {
        generation += 1
        let gen = generation
        guard let url = fileURL else {
            unwatch()
            snapshot = ConnectionsSnapshot()
            finish(.noFile)
            return
        }
        // «Загрузка» — только при первом чтении: перечитывание не должно мигать списком или ошибкой.
        if state == .noFile { state = .loading; onChange?() }
        let sheet = settings.sheetName
        let reader = self.reader
        queue.async { [weak self] in
            let started = DispatchTime.now()
            let result = Result { try reader(url, sheet) }.mapError { $0 as? ConnectionsError ?? .locked }
            let ms = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(result, generation: gen, url: url, milliseconds: ms) }
            }
        }
    }

    private func apply(_ result: Result<ConnectionsSnapshot, ConnectionsError>, generation gen: Int, url: URL, milliseconds: Int) {
        guard gen == generation else { return }
        watch(url)
        switch result {
        case .success(let snap):
            snapshot = snap
            let d = snap.diagnostics
            logger?.log(.loaded(records: d.loaded, skipped: d.skipped.count, duplicates: d.duplicateCount,
                                unrecognizedColumns: d.unrecognizedColumns.count, milliseconds: milliseconds))
            finish(.ready)
        case .failure(let error):
            if attempt < retryBudget(for: error) {
                attempt += 1
                logger?.log(.retrying(error.code, attempt: attempt))
                if error == .cloudNotDownloaded, state != .cloudNotDownloaded { state = .cloudNotDownloaded; onChange?() }
                let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.load() } }
                retryWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
                return
            }
            // Старый список не сохраняем: показывать устаревшие записи хуже, чем ошибку.
            snapshot = ConnectionsSnapshot()
            logger?.log(.loadFailed(error.code))
            switch error {
            case .unavailable, .cloudNotDownloaded: finish(.unavailable)
            default: finish(.failed(error))
            }
        }
    }

    /// Сколько раз повторить чтение после этой ошибки, прежде чем показать её.
    private func retryBudget(for error: ConnectionsError) -> Int {
        switch error {
        case .locked: return Self.busyRetries
        case .cloudNotDownloaded: return Self.cloudRetries
        // Файл пропал, когда список уже был: так выглядит атомарное сохранение (Excel, редакторы).
        case .unavailable: return state == .ready ? Self.busyRetries : 0
        default: return 0
        }
    }

    private func finish(_ s: ConnectionsFileState) {
        state = s
        onChange?()
    }

    /// Чтение файла целиком (вне главного потока). Файл только читается.
    public nonisolated static func read(url: URL, sheet: String?) throws -> ConnectionsSnapshot {
        try ConnectionsSources.source(for: url, sheet: sheet).load(try readData(url))
    }

    /// Имена листов книги — для выбора в настройках. У XML листов нет.
    public nonisolated static func sheetNames(url: URL) throws -> [String] {
        guard ["xlsx", "xlsm"].contains(url.pathExtension.lowercased()) else { return [] }
        return try XLSXSource.sheetNames(in: readData(url))
    }

    nonisolated static func readData(_ url: URL) throws -> Data {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // Старые облачные папки вместо файла держат заглушку «.имя.icloud».
            let stub = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            if fm.fileExists(atPath: stub.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                throw ConnectionsError.cloudNotDownloaded
            }
            throw ConnectionsError.unavailable
        }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey])
        if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status != .current {
            try? fm.startDownloadingUbiquitousItem(at: url)
            throw ConnectionsError.cloudNotDownloaded
        }
        if let size = values?.fileSize, size > ConnectionsSources.maxFileSize { throw ConnectionsError.tooLarge }
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            throw ConnectionsError.unavailable
        } catch {
            throw ConnectionsError.locked
        }
    }

    // MARK: Пароль

    /// Пароль для подключения — из файла сейчас. Вызывающий вводит его и затирает (`SecretBuffer.wipe()`).
    public nonisolated static func password(for record: ConnectionRecord, url: URL, sheet: String?) throws -> SecretBuffer? {
        try ConnectionsSources.source(for: url, sheet: sheet).password(for: record, in: try readData(url))
    }

    public func password(for record: ConnectionRecord) async throws -> SecretBuffer? {
        guard let url = fileURL else { throw ConnectionsError.noFile }
        let sheet = settings.sheetName
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                cont.resume(with: Result { try Self.password(for: record, url: url, sheet: sheet) })
            }
        }
    }

    // MARK: Наблюдение

    /// Следим за файлом; если его нет — за папкой, чтобы заметить, когда он появится.
    private func watch(_ url: URL) {
        let fileFD = open(url.path, O_EVTONLY)
        let path = fileFD >= 0 ? url.path : url.deletingLastPathComponent().path
        if watchedPath == path, watcher != nil {
            if fileFD >= 0 { close(fileFD) }
            return
        }
        unwatch()
        let fd = fileFD >= 0 ? fileFD : open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedPath = path
        let isFile = fileFD >= 0
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Файл заменили (сохранение через переименование) или он появился в папке — открыть заново.
                let replaced = !isFile || !src.data.intersection([.delete, .rename]).isEmpty
                self.scheduleReload(rearm: replaced)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func unwatch() {
        watcher?.cancel()
        watcher = nil
        watchedPath = nil
    }

    private func scheduleReload(rearm: Bool) {
        reloadWork?.cancel()
        if rearm { unwatch() }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
