import Darwin
import Foundation

/// Команда для запуска: программа, аргументы, stdin, окружение и рабочая папка.
package struct CLICommand: Equatable, Sendable {
    package var executable: URL
    package var arguments: [String]
    package var stdin: Data
    package var environment: [String: String]?
    package var directory: URL

    package init(executable: URL, arguments: [String], stdin: Data = Data(), environment: [String: String]? = nil,
                 directory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.environment = environment
        self.directory = directory
    }
}

/// Чем закончился процесс.
package struct CLIExit: Error, Equatable, Sendable {
    package enum Reason: Equatable, Sendable { case exited, timedOut, cancelled, launchFailed }

    package var reason: Reason
    package var status: Int32
    /// Хвост stderr (не больше 16 КБ).
    package var stderr: String
}

/// Запуск внешней программы с таймаутом и отменой: процесс и все его потомки убиваются.
package enum CLIProcess {
    package struct Output: Sendable {
        package var status: Int32
        package var stdout: String
        package var stderr: String
    }

    /// Строки stdout по мере появления. Ненулевой код выхода, таймаут, отмена — `CLIExit`.
    /// Остановка чтения (отмена задачи) убивает процесс.
    package static func lines(_ command: CLICommand, timeout: TimeInterval) -> AsyncThrowingStream<String, Error> {
        open(command, timeout: timeout).lines
    }

    /// Строки и явная остановка. Выход из цикла чтения (`break`, `throw`) сам процесс не останавливает —
    /// остановка только по отмене задачи, поэтому читающий досрочно зовёт `stop` (после конца процесса — ничего не делает).
    package static func open(_ command: CLICommand, timeout: TimeInterval)
        -> (lines: AsyncThrowingStream<String, Error>, stop: @Sendable () -> Void) {
        var runner: Runner?
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let created = Runner(command: command, timeout: timeout,
                                 onLine: { continuation.yield($0) },
                                 onFinish: { exit in
                                     if let exit { continuation.finish(throwing: exit) } else { continuation.finish() }
                                 })
            continuation.onTermination = { termination in
                if case .cancelled = termination { created.stop(.cancelled) }
            }
            runner = created
            created.start()
        }
        let started = runner
        return (lines, { started?.stop(.cancelled) })
    }

    /// Весь вывод сразу (для коротких проверок: `--version`, `login status`). Код выхода не считается ошибкой.
    package static func run(_ command: CLICommand, timeout: TimeInterval) async throws -> Output {
        var stdout = ""
        do {
            for try await line in lines(command, timeout: timeout) { stdout += line + "\n" }
            return Output(status: 0, stdout: stdout, stderr: "")
        } catch let exit as CLIExit where exit.reason == .exited {
            return Output(status: exit.status, stdout: stdout, stderr: exit.stderr)
        }
    }
}

/// Один процесс: чтение stdout построчно, stderr в буфер, запись stdin в фоне, таймаут.
private final class Runner: @unchecked Sendable {
    private let command: CLICommand
    private let timeout: TimeInterval
    private let onLine: (String) -> Void
    private let onFinish: (CLIExit?) -> Void

    private let lock = NSLock()
    private let process = Process()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stopReason: CLIExit.Reason?
    private var finished = false
    private let outputDone = DispatchGroup()

    init(command: CLICommand, timeout: TimeInterval, onLine: @escaping (String) -> Void,
         onFinish: @escaping (CLIExit?) -> Void) {
        self.command = command
        self.timeout = timeout
        self.onLine = onLine
        self.onFinish = onFinish
    }

    func start() {
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.directory
        if let environment = command.environment { process.environment = environment }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        outputDone.enter()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.flushStdout(final: true)
                self.outputDone.leave()
            } else {
                self.lock.withLock { self.stdoutBuffer.append(data) }
                self.flushStdout(final: false)
            }
        }
        outputDone.enter()
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.outputDone.leave()
            } else {
                self.lock.withLock {
                    self.stderrBuffer.append(data)
                    if self.stderrBuffer.count > 16_384 { self.stderrBuffer = self.stderrBuffer.suffix(16_384) }
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            // Ждём конец вывода: потомки могли держать трубы, поэтому не дольше 2 с.
            DispatchQueue.global().async {
                _ = self.outputDone.wait(timeout: .now() + 2)
                self.finish(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            lock.withLock { stopReason = .launchFailed }
            finish(status: -1, launchError: error.localizedDescription)
            return
        }
        writeInput(to: stdin.fileHandleForWriting)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop(.timedOut) }
    }

    /// Остановить: SIGTERM группе процесса и потомкам, через 2 с — SIGKILL оставшимся.
    func stop(_ reason: CLIExit.Reason) {
        // Причина — только если есть кого останавливать: процесс мог уже выйти и ждать конца вывода (до 2 с),
        // и таймаут в это окно не должен превращать успешный ответ в «не ответил».
        let pid: pid_t? = lock.withLock {
            guard !finished, stopReason == nil, process.isRunning else { return nil }
            stopReason = reason
            return process.processIdentifier
        }
        guard let pid else { return }
        // Process запускает программу лидером своей группы (pgid = pid): сигнал группе достаёт и потомков,
        // которых ещё не было в снимке дерева (породились в момент остановки). Дерево — для ушедших в свою группу.
        let tree = ProcessTree.descendants(of: pid) + [pid]
        kill(-pid, SIGTERM)
        for child in tree { kill(child, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
            for child in tree where ProcessTree.isAlive(child) { kill(child, SIGKILL) }
        }
    }

    /// stdin пишется в фоне: большой текст (расшифровка встречи) не помещается в буфер трубы.
    /// Без SIGPIPE: если программа закрылась раньше, запись просто прекращается.
    private func writeInput(to handle: FileHandle) {
        let data = command.stdin
        DispatchQueue.global(qos: .userInitiated).async {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, base + offset, raw.count - offset)
                    if written > 0 { offset += written } else if written < 0, errno == EINTR { continue } else { break }
                }
            }
            try? handle.close()
        }
    }

    private func flushStdout(final: Bool) {
        var lines: [String] = []
        lock.withLock {
            while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                let line = stdoutBuffer[stdoutBuffer.startIndex..<newline]
                lines.append(String(decoding: line, as: UTF8.self))
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            }
            if final, !stdoutBuffer.isEmpty {
                lines.append(String(decoding: stdoutBuffer, as: UTF8.self))
                stdoutBuffer.removeAll()
            }
        }
        for line in lines { onLine(line.hasSuffix("\r") ? String(line.dropLast()) : line) }
    }

    private func finish(status: Int32, launchError: String? = nil) {
        let state: (reason: CLIExit.Reason?, stderr: String)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return (stopReason, String(decoding: stderrBuffer, as: UTF8.self))
        }
        guard let state else { return }
        if let reason = state.reason {
            onFinish(CLIExit(reason: reason, status: status, stderr: launchError ?? state.stderr))
        } else if status != 0 {
            onFinish(CLIExit(reason: .exited, status: status, stderr: state.stderr))
        } else {
            onFinish(nil)
        }
    }
}

/// Потомки процесса (codex — node, который запускает свою программу).
package enum ProcessTree {
    package static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [pid]
        while let current = queue.popLast(), result.count < 256 {
            let count = proc_listchildpids(current, nil, 0)
            guard count > 0 else { continue }
            var children = [pid_t](repeating: 0, count: Int(count) + 8)
            let filled = children.withUnsafeMutableBytes { proc_listchildpids(current, $0.baseAddress, Int32($0.count)) }
            let found = children.prefix(max(0, Int(filled))).filter { $0 > 0 }
            result += found
            queue += found
        }
        return result
    }

    package static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
}
