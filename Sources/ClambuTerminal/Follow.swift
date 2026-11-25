import ClambuCore
import Foundation
import SwiftTUICLI

public enum Follow {
    @MainActor public static func run(_ monitor: Monitor, untilDone: Bool) async throws {
        if isatty(1) == 0 || isatty(0) == 0 {
            await plain(monitor, untilDone: untilDone)
            return
        }
        let model = PanelModel(monitor: monitor)
        model.start()
        defer { model.stop() }
        let term = InlineTerminal()
        term.begin()
        defer { term.end() }

        let start = model.snap.state
        term.log(logLine(Event(.state, "following \(start.job.isEmpty ? "the printer" : start.job), \(start.label)" + (start.busy ? " at \(start.percent ?? 0)%" : ""), state: start)))
        let events = monitor.events()
        let pending = Pending()
        let listener = Task { @MainActor in
            for await e in events where e.notable { pending.add(e) }
        }
        defer { listener.cancel() }

        var wasBusy = start.busy
        var lastTab = ""
        while !term.interrupted && !model.quit {
            for e in pending.take() { term.show(e) }
            term.panel(model)
            let tab = HUD.tabProgress(model.snap.state)
            if tab != lastTab { term.write(tab); lastTab = tab }
            if let c = term.readKey() { model.key(c) }
            let s = model.snap.state
            if s.busy { wasBusy = true }
            if untilDone && wasBusy && !s.busy && s.state != nil {
                for _ in 0..<600 where monitor.finishing && !term.interrupted {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                for e in pending.take() { term.show(e) }
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        term.write(HUD.tabProgress(nil))
        term.finish(summary(model.snap.state))
    }

    static func plain(_ monitor: Monitor, untilDone: Bool) async {
        let start = monitor.snapshot().state
        print(start.oneline); fflush(stdout)
        var wasBusy = start.busy
        for await e in monitor.events() {
            if e.kind == .layer, let s = e.state, e.notable { print(s.oneline) }
            else if e.notable { print("\(timeOfDay(e.at))  \(e.message)" + (e.path.map { "  \($0)" } ?? "")) }
            fflush(stdout)
            if let s = e.state, e.kind == .status {
                if s.busy { wasBusy = true } else if untilDone && wasBusy { break }
            }
        }
    }

    static func summary(_ s: PrinterState) -> String {
        let time = Piece(timeOfDay() + "  ", Palette.dim)
        let job = Piece(s.job.isEmpty ? "the print" : s.job, Palette.text, bold: true)
        switch s.state {
        case "FINISH":
            return ansi([time, Piece("✓ ", Palette.sand), job, Piece(" finished", Palette.sand)])
        case "FAILED":
            return ansi([time, Piece("✗ ", Palette.red), job, Piece(" failed", Palette.red)])
        default:
            guard s.busy else { return ansi([time] + badge(s)) }
            var p = [time] + badge(s) + [Piece("  " + s.job, Palette.text), Piece("  \(s.percent ?? 0)%", Palette.text)]
            if let at = s.finishAt { p.append(Piece("  done \(timeOfDay(at))", Palette.dim)) }
            p.append(Piece("   clambu stopped following; the print goes on", Palette.dim))
            return ansi(p)
        }
    }
}

@MainActor final class Pending {
    private var list: [Event] = []
    func add(_ e: Event) { list.append(e) }
    func take() -> [Event] { defer { list.removeAll() }; return list }
}

func logLine(_ e: Event) -> String {
    let color: UInt32
    switch e.kind {
    case .alert: color = Palette.red
    case .error: color = Palette.amber
    case .finished: color = e.to == "FAILED" ? Palette.red : Palette.sand
    case .state: color = Palette.tone(e.state?.tone ?? .quiet)
    case .plate: color = e.plate?.verdict == "clear" ? Palette.green : Palette.amber
    default: color = Palette.text
    }
    var line = ansi([Piece(timeOfDay(e.at) + "  ", Palette.dim), Piece(e.message, color, bold: e.kind == .state || e.kind == .finished)])
    if let p = e.path, e.kind != .frame {
        let short = p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        line += "  " + "\u{1B}]8;;file://\(p)\u{1B}\\" + ansi([Piece(short, Palette.dim)]) + "\u{1B}]8;;\u{1B}\\"
    }
    return line
}

func ansi(_ pieces: [Piece]) -> String {
    pieces.map { Palette.ansi($0.text, $0.color, bold: $0.bold) }.joined()
}

@MainActor final class InlineTerminal {
    private var height = 0
    private var width = 0
    private var saved = termios()
    private var raw = false
    private var lastPanel = ""
    private var sigint: DispatchSourceSignal?
    private(set) var interrupted = false

    func begin() {
        width = terminalSize().0
        enterRaw()
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.interrupted = true } }
        src.resume()
        sigint = src
        write("\u{1B}[?25l")
    }

    func end() {
        if raw { leaveRaw() }
        sigint?.cancel()
        signal(SIGINT, SIG_DFL)
        write("\u{1B}[?25h")
    }

    private func enterRaw() {
        tcgetattr(0, &saved)
        var t = saved
        t.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(0, TCSANOW, &t)
        raw = true
    }

    private func leaveRaw() {
        tcsetattr(0, TCSADRAIN, &saved)
        raw = false
    }

    func write(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

    private var erase: String {
        guard height > 0 else { return "" }
        let now = terminalSize().0
        var rows = height
        if now < width - 1 { rows = height * Int((Double(width - 1) / Double(max(now, 1))).rounded(.up)) }
        return "\r" + (rows > 1 ? "\u{1B}[\(rows - 1)A" : "") + "\u{1B}[J"
    }

    func show(_ e: Event) {
        log(logLine(e))
        if let path = e.path, e.kind == .message, path.hasSuffix(".jpg") { image(path) }
    }

    func log(_ line: String) {
        write("\u{1B}[?2026h" + erase + line + "\u{1B}[K\n" + lastPanel + "\u{1B}[?2026l")
        height = lastPanel.isEmpty ? 0 : lastPanel.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    func image(_ path: String) {
        guard let seq = InlineImage.sequence(path: path, cols: min(56, terminalSize().0 - 4)) else { return }
        write("\u{1B}[?2026h" + erase + seq + "\n" + lastPanel + "\u{1B}[?2026l")
    }

    func panel(_ model: PanelModel) {
        let cols = terminalSize().0
        let text = RenderOnce.render(PanelView(model: model, width: cols - 1), width: cols - 1, isStdoutTTY: true)
            .trimmingCharacters(in: .newlines)
        guard text != lastPanel || cols != width else { return }
        write("\u{1B}[?2026h" + erase + text + "\u{1B}[?2026l")
        lastPanel = text
        height = text.split(separator: "\n", omittingEmptySubsequences: false).count
        width = cols
    }

    func finish(_ line: String) {
        write(erase + line + "\u{1B}[K\n")
        height = 0; lastPanel = ""
    }

    func readKey() -> Character? {
        var fds = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        guard poll(&fds, 1, 0) > 0 else { return nil }
        var c: UInt8 = 0
        guard read(0, &c, 1) == 1 else { return nil }
        if c == 3 { interrupted = true; return nil }
        return Character(UnicodeScalar(c))
    }
}
