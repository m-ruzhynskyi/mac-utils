import AppKit
import MUHiddenScreen

// Процесс-помощник «Скрытого экрана»: держит виртуальный дисплей, пока жив, и прячет программы ИИ,
// если Mac Utils пропала (падение, «Завершить принудительно»). Запускает его Mac Utils (`HelperDisplayHost`),
// команды — строками в stdin (`HelperCommand`), ответы — в stdout (`HelperMessage`). Без Dock и окон.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let parent = getppid()
var display: HiddenDisplay?
var apps: [String] = []

func send(_ message: HelperMessage) {
    print(message.line)
}

func hideApps() {
    for app in NSWorkspace.shared.runningApplications where apps.contains(app.bundleIdentifier ?? "") {
        app.hide()
    }
}

func finish(hiding: Bool) -> Never {
    if hiding {
        hideApps()
        // Дать программам спрятаться до того, как macOS начнёт переносить окна со снятого дисплея.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
    display?.close()
    display = nil
    exit(0)
}

func handle(_ command: HelperCommand) {
    switch command {
    case let .open(width, height):
        guard display == nil else { return }
        let created = HiddenDisplay(pointSize: CGSize(width: width, height: height))
        do {
            try created.open {
                // Система сама сняла дисплей: окна уже переезжают — прячем и сообщаем.
                hideApps()
                send(.terminated)
            }
            display = created
            send(.display(created.displayID))
        } catch {
            send(.failed(String(describing: error)))
        }
    case let .apps(ids):
        apps = ids
    case .quit:
        finish(hiding: false)
    case .hideAndQuit:
        finish(hiding: true)
    }
}

// Mac Utils пропала: родитель сменился (процесс усыновил launchd) или труба закрылась.
let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
parentWatch.setEventHandler { finish(hiding: true) }
parentWatch.resume()

var buffer = LineBuffer()
let input = FileHandle.standardInput
input.readabilityHandler = { fileHandle in
    let data = fileHandle.availableData
    DispatchQueue.main.async {
        guard !data.isEmpty else { finish(hiding: true) }
        for line in buffer.append(String(decoding: data, as: UTF8.self)) {
            if let command = HelperCommand(line: line) { handle(command) }
        }
    }
}

// Родитель мог умереть до установки наблюдения.
if getppid() != parent { finish(hiding: true) }
RunLoop.main.run()
