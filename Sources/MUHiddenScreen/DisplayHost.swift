import AppKit
import MUCore

/// Кто держит скрытый дисплей. По умолчанию — процесс-помощник (переживает падение Mac Utils и прячет программы);
/// если помощника нет или он не ответил — сама Mac Utils (как в первой проверке).
@MainActor
protocol DisplayHosting: AnyObject {
    var name: String { get }
    /// `onReady` — один раз: номер дисплея или ошибка. `onLost` — дисплей пропал позже (помощник упал, система сняла дисплей).
    func open(size: CGSize, apps: [String], onReady: @escaping (Result<CGDirectDisplayID, Error>) -> Void, onLost: @escaping () -> Void)
    func update(apps: [String])
    /// `hiding` — спрятать программы до снятия дисплея (выход Mac Utils); без него — окна уже возвращены.
    func close(hiding: Bool)
}

enum DisplayHostError: Error, CustomStringConvertible {
    case helperMissing
    case helperTimeout
    case helper(String)
    case display(HiddenDisplay.Failure)

    var description: String {
        switch self {
        case .helperMissing: return "помощник не найден"
        case .helperTimeout: return "помощник не ответил за 3 с"
        case let .helper(text): return "помощник: \(text)"
        case let .display(failure): return "дисплей: \(failure)"
        }
    }
}

/// Дисплей в процессе Mac Utils: при падении Mac Utils окна выпадут на основной экран.
@MainActor
final class InProcessDisplayHost: DisplayHosting {
    let name = "в процессе Mac Utils"
    private var display: HiddenDisplay?

    func open(size: CGSize, apps: [String], onReady: @escaping (Result<CGDirectDisplayID, Error>) -> Void, onLost: @escaping () -> Void) {
        let display = HiddenDisplay(pointSize: size)
        do {
            try display.open { Task { @MainActor in onLost() } }
            self.display = display
            onReady(.success(display.displayID))
        } catch let failure as HiddenDisplay.Failure {
            onReady(.failure(DisplayHostError.display(failure)))
        } catch {
            onReady(.failure(error))
        }
    }

    func update(apps: [String]) {}

    func close(hiding: Bool) {
        display?.close()
        display = nil
    }
}

/// Процесс-помощник `HiddenScreenHelper` (рядом с исполняемым файлом Mac Utils, в бандле — Contents/MacOS).
@MainActor
final class HelperDisplayHost: DisplayHosting {
    let name = "процесс-помощник"
    private var process: Process?
    private var input: FileHandle?
    private var buffer = LineBuffer()
    private var ready: ((Result<CGDirectDisplayID, Error>) -> Void)?
    private var lost: (() -> Void)?
    private var closing = false

    static var executableURL: URL? {
        let candidates = [Bundle.main.url(forAuxiliaryExecutable: "HiddenScreenHelper"),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("HiddenScreenHelper")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func open(size: CGSize, apps: [String], onReady: @escaping (Result<CGDirectDisplayID, Error>) -> Void, onLost: @escaping () -> Void) {
        guard let url = Self.executableURL else {
            onReady(.failure(DisplayHostError.helperMissing))
            return
        }
        ready = onReady
        lost = onLost
        let process = Process()
        process.executableURL = url
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            Task { @MainActor in self?.received(text) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.exited(status: status) }
        }
        do {
            try process.run()
        } catch {
            finishReady(.failure(error))
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        Log.hiddenScreen.info("помощник запущен, pid \(process.processIdentifier)")
        send(.apps(apps))
        send(.open(width: Int(size.width), height: Int(size.height)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.ready != nil else { return }
                self.finishReady(.failure(DisplayHostError.helperTimeout))
                self.close(hiding: false)
            }
        }
    }

    func update(apps: [String]) { send(.apps(apps)) }

    func close(hiding: Bool) {
        guard let process else { return }
        closing = true
        send(hiding ? .hideAndQuit : .quit)
        try? input?.close()
        input = nil
        // Помощник выходит сам; если завис — снять через секунду (дисплей уйдёт вместе с ним).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if process.isRunning { process.terminate() }
        }
        self.process = nil
    }

    private func send(_ command: HelperCommand) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command.line + "\n").utf8))
    }

    private func received(_ text: String) {
        for line in buffer.append(text) {
            guard let message = HelperMessage(line: line) else { continue }
            Log.hiddenScreen.info("помощник: \(message.line, privacy: .public)")
            switch message {
            case let .display(id): finishReady(.success(id))
            case let .failed(reason): finishReady(.failure(DisplayHostError.helper(reason)))
            case .terminated: if !closing { lost?() }
            }
        }
    }

    private func exited(status: Int32) {
        Log.hiddenScreen.info("помощник завершился, код \(status)")
        finishReady(.failure(DisplayHostError.helper("завершился, код \(status)")))
        if !closing { lost?() }
        process = nil
    }

    private func finishReady(_ result: Result<CGDirectDisplayID, Error>) {
        guard let ready else { return }
        self.ready = nil
        ready(result)
    }
}
