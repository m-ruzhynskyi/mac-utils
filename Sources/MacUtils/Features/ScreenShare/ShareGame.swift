import AppKit
import SwiftUI

/// Крестики-нолики: поле и правила. Ходят по очереди, первым — крестики.
/// Кто пригласил — играет крестиками в первой партии, дальше начинают по очереди.
struct TicTacToe: Equatable {
    enum Mark: Equatable { case x, o }

    private(set) var cells: [Mark?] = Array(repeating: nil, count: 9)
    private(set) var round = 0

    static let lines = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]]

    var turn: Mark { cells.compactMap { $0 }.count % 2 == 0 ? .x : .o }
    var winLine: [Int]? {
        Self.lines.first { line in
            guard let mark = cells[line[0]] else { return false }
            return cells[line[1]] == mark && cells[line[2]] == mark
        }
    }
    var winner: Mark? { winLine.flatMap { cells[$0[0]] } }
    var isDraw: Bool { winner == nil && !cells.contains(nil) }
    var isOver: Bool { winner != nil || isDraw }

    @discardableResult
    mutating func play(_ cell: Int) -> Bool {
        guard (0..<9).contains(cell), cells[cell] == nil, !isOver else { return false }
        cells[cell] = turn
        return true
    }

    /// Новая партия с номером `round` (номер приходит в сообщении — так обе стороны не разойдутся).
    mutating func start(round: Int) {
        cells = Array(repeating: nil, count: 9)
        self.round = round
    }

    /// Каким знаком играет пригласивший (или приглашённый) в этой партии.
    func mark(inviter: Bool) -> Mark { (round % 2 == 0) == inviter ? .x : .o }
}

/// Партия между ведущим и одним зрителем во время трансляции.
/// Сообщения идут через ретранслятор: {"type":"game","action":"invite|accept|decline|move|again|quit", "cell", "round"};
/// ретранслятор доставляет их только собеседнику (ведущему — с ID зрителя в "from").
@MainActor
final class ShareGame: ObservableObject {
    static let shared = ShareGame()

    enum Phase: Equatable { case none, inviting, invited, playing, ended(String) }

    @Published private(set) var phase: Phase = .none
    @Published private(set) var board = TicTacToe()
    @Published private(set) var peerName = ""
    @Published private(set) var score = (me: 0, peer: 0)

    /// ID зрителя (у ведущего) или "host" (у зрителя).
    private(set) var peer = ""
    private var iInvited = false
    private var transport: (([String: Any]) -> Void)?

    var myMark: TicTacToe.Mark { board.mark(inviter: iInvited) }
    var myTurn: Bool { phase == .playing && !board.isOver && board.turn == myMark }
    var isActive: Bool {
        switch phase {
        case .inviting, .invited, .playing: true
        default: false
        }
    }

    func invite(peer: String, name: String, transport: @escaping ([String: Any]) -> Void) {
        if isActive { quit() }
        begin(peer: peer, name: name, transport: transport, inviter: true)
        phase = .inviting
        send(["action": "invite"])
        ShareGameWindow.shared.show()
    }

    /// Сообщение игры от собеседника.
    func receive(_ json: [String: Any], peer: String, name: String, transport: @escaping ([String: Any]) -> Void) {
        let action = json["action"] as? String ?? ""
        // Уже играем с другим — новому вежливо отказываем, остальное от него не наше.
        if isActive, peer != self.peer {
            if action == "invite" { transport(["type": "game", "action": "decline", "busy": true]) }
            return
        }
        switch action {
        case "invite":
            begin(peer: peer, name: name, transport: transport, inviter: false)
            phase = .invited
            ShareGameWindow.shared.show()
            Feedback.play("Glass")
        case "accept" where phase == .inviting:
            phase = .playing
        case "decline" where phase == .inviting:
            phase = .ended(json["busy"] as? Bool == true ? "\(peerName) уже играет с другим" : "\(peerName) не хочет играть")
        case "move" where phase == .playing:
            guard let cell = json["cell"] as? Int, json["round"] as? Int == board.round, board.turn != myMark else { return }
            if board.play(cell) { tally() }
        case "again" where phase == .playing:
            if let round = json["round"] as? Int, round > board.round { board.start(round: round) }
        case "quit" where isActive:
            phase = .ended("\(peerName) вышел из игры")
        default:
            break
        }
    }

    func accept() {
        guard phase == .invited else { return }
        phase = .playing
        send(["action": "accept"])
    }

    func decline() {
        guard phase == .invited else { return }
        send(["action": "decline"])
        phase = .none
        ShareGameWindow.shared.close()
    }

    func play(_ cell: Int) {
        guard myTurn, board.play(cell) else { return }
        send(["action": "move", "cell": cell, "round": board.round])
        tally()
    }

    func again() {
        guard phase == .playing else { return }
        board.start(round: board.round + 1)
        send(["action": "again", "round": board.round])
    }

    func quit() {
        if isActive { send(["action": "quit"]) }
        phase = .none
        transport = nil
    }

    /// Собеседник ушёл из трансляции или эфир закончился.
    func peerGone(_ peer: String? = nil) {
        guard isActive, peer == nil || peer == self.peer else { return }
        phase = .ended("Игра закончилась: \(peerName) больше не в трансляции")
        transport = nil
    }

    private func begin(peer: String, name: String, transport: @escaping ([String: Any]) -> Void, inviter: Bool) {
        if self.peer != peer { score = (0, 0) }
        self.peer = peer
        peerName = name.isEmpty ? "Собеседник" : name
        self.transport = transport
        iInvited = inviter
        board = TicTacToe()
    }

    private func tally() {
        guard let winner = board.winner else { return }
        if winner == myMark { score.me += 1 } else { score.peer += 1 }
    }

    private func send(_ fields: [String: Any]) {
        transport?(fields.merging(["type": "game"]) { current, _ in current })
    }

    /// JSON для сокета.
    static func text(_ fields: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Окно игры

@MainActor
final class ShareGameWindow {
    static let shared = ShareGameWindow()
    private var panel: NSPanel?

    func show() {
        let panel = self.panel ?? make()
        panel.orderFrontRegardlessOnScreen()
        panel.makeKey()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Крестики-нолики"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: TicTacToeView(game: .shared))
        panel.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                let game = ShareGame.shared
                if game.phase == .invited { game.decline() } else { game.quit() }
            }
        }
        self.panel = panel
        return panel
    }
}

struct TicTacToeView: View {
    @ObservedObject var game: ShareGame

    var body: some View {
        VStack(spacing: 14) {
            Text("С \(game.peerName)").font(.headline)
            switch game.phase {
            case .inviting:
                ProgressView().controlSize(.small)
                Text("Ждём, пока \(game.peerName) согласится…").foregroundStyle(.secondary)
                Button("Отменить") { game.quit(); ShareGameWindow.shared.close() }
            case .invited:
                Text("\(game.peerName) зовёт сыграть в крестики-нолики").multilineTextAlignment(.center)
                HStack {
                    Button("Отказаться") { game.decline() }
                    Button("Играть") { game.accept() }.keyboardShortcut(.defaultAction)
                }
            case .playing:
                Text(status).font(.title3.weight(.semibold)).foregroundStyle(statusColor)
                grid
                HStack {
                    Text("Вы \(game.score.me) : \(game.score.peer) \(game.peerName)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if game.board.isOver { Button("Ещё раз") { game.again() }.keyboardShortcut(.defaultAction) }
                }
            case .ended(let message):
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Закрыть") { ShareGameWindow.shared.close() }
            case .none:
                Text("Игра закончилась").foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 290)
    }

    private var status: String {
        let board = game.board
        if let winner = board.winner { return winner == game.myMark ? "Вы выиграли! 🎉" : "Победа: \(game.peerName)" }
        if board.isDraw { return "Ничья" }
        return game.myTurn ? "Ваш ход (\(symbol(game.myMark)))" : "Ходит \(game.peerName)…"
    }

    private var statusColor: Color {
        if let winner = game.board.winner { return winner == game.myMark ? .green : .red }
        return game.myTurn ? .accentColor : .secondary
    }

    private var grid: some View {
        let line = game.board.winLine ?? []
        return VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { column in
                        let cell = row * 3 + column
                        Button { game.play(cell) } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(line.contains(cell) ? Color.green.opacity(0.25) : Color.primary.opacity(0.07))
                                if let mark = game.board.cells[cell] {
                                    Text(symbol(mark)).font(.system(size: 38, weight: .bold))
                                        .foregroundStyle(mark == .x ? Color.blue : Color.orange)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .frame(width: 76, height: 76)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!game.myTurn || game.board.cells[cell] != nil)
                    }
                }
            }
        }
        .animation(.spring(duration: 0.25), value: game.board)
    }

    private func symbol(_ mark: TicTacToe.Mark) -> String { mark == .x ? "✕" : "◯" }
}
