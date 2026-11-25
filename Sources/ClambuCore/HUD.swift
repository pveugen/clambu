import Foundation

public enum HUD {
    public static var path: String { Paths.cache + "/state.json" }

    public struct File: Codable, Sendable {
        public var pid: Int32
        public var written: Date
        public var connected: Bool
        public var state: PrinterState
        public var plate: PlateState?
        public var url: String?
        public var tailnetURL: String?
        public var frameAt: Date?
    }

    static func file(_ s: Snapshot) -> File {
        File(pid: getpid(), written: Date(), connected: s.connected, state: s.state, plate: s.plate,
             url: s.localURL, tailnetURL: s.tailnetURL, frameAt: s.frameAt)
    }

    static func write(_ s: Snapshot) {
        try? FileManager.default.createDirectory(atPath: Paths.cache, withIntermediateDirectories: true)
        guard let d = try? JSON.encoder(pretty: false).encode(file(s)) else { return }
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func clear() {
        guard let f = read(), f.pid == getpid() else { return }
        if f.state.state == "FINISH" || f.state.state == "FAILED" { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    static func read() -> File? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSON.decoder().decode(File.self, from: d)
    }

    public static let showFinished: TimeInterval = 60 * 60

    public static func current(now: Date = Date()) -> File? {
        guard let f = read() else { return nil }
        let age = now.timeIntervalSince(f.written)
        if f.state.state == "FINISH" || f.state.state == "FAILED" { return age < showFinished ? f : nil }
        guard age < 30, alive(f.pid) else { return nil }
        return worthShowing(f)
    }

    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    public enum Style: Sendable {
        case ansi
        case tmux(background: String)
        case plain
    }

    public static func line(_ f: File?, style: Style, width: Int = 64) -> String? {
        guard let f else { return nil }
        let s = f.state
        var parts: [Piece] = []
        let tone = Palette.tone(s.tone)
        let job = s.job.isEmpty ? "print" : String(s.job.prefix(24))
        let dot: String
        switch s.state {
        case "PAUSE": dot = "⏸"
        case "FINISH": dot = "✓"
        case "FAILED": dot = "✗"
        default: dot = s.alerts.isEmpty ? "●" : "▲"
        }
        parts.append(Piece(dot, tone))
        parts.append(Piece(" " + job, Palette.text, bold: true))
        if !f.connected {
            parts.append(Piece("  lost the printer", Palette.amber))
        } else if let a = s.alerts.first {
            parts.append(Piece("  " + a, Palette.red))
        } else {
            switch s.state {
            case "RUNNING", "PAUSE":
                let pct = s.percent ?? 0
                parts.append(Piece(String(format: " %3d%% ", pct), Palette.text))
                let barWidth = max(4, min(12, width - 52))
                parts += bar(Double(pct) / 100, width: barWidth, color: s.state == "PAUSE" ? Palette.amber : Palette.sand)
                if let l = s.layer, let t = s.totalLayers { parts.append(Piece("  L\(l)/\(t)", Palette.dim)) }
                if s.state == "PAUSE" {
                    parts.append(Piece("  paused", Palette.amber))
                } else if let at = s.finishAt {
                    parts.append(Piece("  done ", Palette.dim))
                    parts.append(Piece(timeOfDay(at), Palette.text))
                }
            case "PREPARE":
                parts.append(Piece("  heating up ", Palette.blue))
                parts.append(Piece("\(s.nozzle)°", Palette.text))
                parts.append(Piece("/\(s.nozzleTarget)°", Palette.dim))
            case "FINISH":
                parts.append(Piece("  finished ", Palette.sand))
                parts.append(Piece(timeOfDay(f.written), Palette.dim))
            case "FAILED":
                parts.append(Piece("  failed", Palette.red))
            default:
                parts.append(Piece("  " + s.label, Palette.dim))
            }
        }
        return render(parts, style)
    }

    static func render(_ parts: [Piece], _ style: Style) -> String {
        switch style {
        case .plain:
            return parts.map(\.text).joined()
        case .ansi:
            return parts.map { Palette.ansi($0.text, $0.color, bold: $0.bold) }.joined()
        case .tmux(let bg):
            let body = parts.map { p in
                "#[fg=\(Palette.hex(p.color)),bg=\(bg)\(p.bold ? ",bold" : ",nobold")]" + p.text.replacingOccurrences(of: "#", with: "##")
            }.joined()
            return "#[fg=\(bg),bg=default]\u{E0B6}" + "#[bg=\(bg)] " + body + " #[fg=\(bg),bg=default,nobold]\u{E0B4}#[default]"
        }
    }

    public static func tabProgress(_ s: PrinterState?, inTmux: Bool = ProcessInfo.processInfo.environment["TMUX"] != nil) -> String {
        let seq: String
        switch s?.state {
        case "RUNNING"?: seq = "\u{1B}]9;4;1;\(min(max(s?.percent ?? 0, 0), 100))\u{07}"
        case "PAUSE"?: seq = "\u{1B}]9;4;4;\(min(max(s?.percent ?? 0, 0), 100))\u{07}"
        case "PREPARE"?: seq = "\u{1B}]9;4;3\u{07}"
        case "FAILED"?: seq = "\u{1B}]9;4;2;100\u{07}"
        default: seq = "\u{1B}]9;4;0\u{07}"
        }
        guard inTmux else { return seq }
        return "\u{1B}Ptmux;" + seq.replacingOccurrences(of: "\u{1B}", with: "\u{1B}\u{1B}") + "\u{1B}\\"
    }

    public static func startFollower(printer: String, now: Date = Date()) {
        let mark = Paths.cache + "/follower-checked"
        if let a = try? FileManager.default.attributesOfItem(atPath: mark)[.modificationDate] as? Date,
           now.timeIntervalSince(a) < 120 { return }
        try? FileManager.default.createDirectory(atPath: Paths.cache, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mark, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        p.arguments = ["watch", "--printer", printer, "--frames", "0"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    public static func isThisMachine(_ host: String) -> Bool {
        let short = { (s: String) in s.split(separator: ".").first.map { $0.lowercased() } ?? "" }
        let me = short(ProcessInfo.processInfo.hostName)
        let named = short(host)
        if named == "localhost" || named == "127" { return true }
        if named == me { return true }
        return tailscaleSelf().map { short($0.name) == named || $0.ip == host } ?? false
    }

    public static func remote(_ host: String, port: Int = 8765, timeout: TimeInterval = 1.5, now: Date = Date()) -> File? {
        let cache = Paths.cache + "/remote-\(host).json"
        if let a = try? FileManager.default.attributesOfItem(atPath: cache)[.modificationDate] as? Date, now.timeIntervalSince(a) < 10 {
            guard let d = FileManager.default.contents(atPath: cache), !d.isEmpty else { return nil }
            return (try? JSON.decoder().decode(File.self, from: d)).flatMap(worthShowing)
        }
        var file: File?
        if let url = URL(string: "http://\(host):\(port)/api/status") {
            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let done = DispatchSemaphore(value: 0)
            let box = Box<Data?>(nil)
            URLSession.shared.dataTask(with: req) { d, r, _ in
                if (r as? HTTPURLResponse)?.statusCode == 200 { box.value = d }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + timeout + 0.5)
            if let d = box.value, let s = try? JSON.decoder().decode(APIStatus.self, from: d) {
                file = File(pid: 0, written: now, connected: s.connected, state: s.state, plate: s.plate, url: s.url,
                            tailnetURL: s.tailnetURL, frameAt: s.frameAt)
            }
        }
        try? FileManager.default.createDirectory(atPath: Paths.cache, withIntermediateDirectories: true)
        try? (file.flatMap { try? JSON.encoder(pretty: false).encode($0) } ?? Data()).write(to: URL(fileURLWithPath: cache), options: .atomic)
        return file.flatMap(worthShowing)
    }

    static func worthShowing(_ f: File) -> File? {
        switch f.state.state {
        case "FINISH", "FAILED": return f
        default: return f.state.busy || !f.state.alerts.isEmpty ? f : nil
        }
    }
}
