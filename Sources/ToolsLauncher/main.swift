import AppKit

// «Инструменты»: значок в Программах, Launchpad и Dock. Просит Mac Utils
// открыть окно инструментов (и запускает его, если он ещё не запущен).
if let url = URL(string: "macutils://tools") {
    NSWorkspace.shared.open(url)
}
