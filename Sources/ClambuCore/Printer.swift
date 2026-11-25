import Foundation

public final class Printer: @unchecked Sendable {
    let cfg: PrinterConfig
    private var sock: TLSSocket?
    private let lock = NSLock()
    private var report: [String: Any] = [:]
    private var readTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var topic: String { "device/\(cfg.serial)/request" }

    public init(_ cfg: PrinterConfig) { self.cfg = cfg }

    public func connect() async throws {
        let s = TLSSocket(host: cfg.ip, port: 8883)
        do { try await s.open() } catch {
            throw Stop("cannot reach the printer at \(cfg.ip):8883 (\(error)). Inside a sandbox, the LAN is blocked.", .unreachable)
        }
        sock = s
        var v = Data(mqttString("MQTT")) + Data([4, 0xC2, 0, 30])
        v += mqttString("clambu-\(getpid())") + mqttString("bblp") + mqttString(cfg.accessCode)
        try await s.send(packet(0x10, v))
        let head = try await s.read(4)
        guard head[0] == 0x20 else { throw Stop("unexpected MQTT reply from the printer", .unreachable) }
        if head[3] != 0 {
            throw Stop("MQTT login refused (\(head[3])). Check the access code and Developer Mode.", .unreachable)
        }
        try await s.send(packet(0x82, Data([0, 1]) + mqttString("device/\(cfg.serial)/report") + Data([0])))
        readTask = Task { [weak self] in await self?.readLoop() }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                try? await self?.sock?.send(Data([0xC0, 0]))
            }
        }
    }

    public func close() {
        readTask?.cancel(); pingTask?.cancel()
        if let s = sock { Task { try? await s.send(Data([0xE0, 0])); s.close() } }
        sock = nil
    }

    private func readLoop() async {
        guard let s = sock else { return }
        while !Task.isCancelled {
            do {
                let type = try await s.read(1)[0]
                var len = 0, mult = 1
                while true {
                    let b = try await s.read(1)[0]
                    len += Int(b & 0x7F) * mult
                    mult *= 128
                    if b & 0x80 == 0 { break }
                }
                let body = len > 0 ? try await s.read(len) : Data()
                if type >> 4 == 3 { handlePublish(type, body) }
            } catch {
                return
            }
        }
    }

    private func handlePublish(_ type: UInt8, _ body: Data) {
        guard body.count > 2 else { return }
        let tlen = Int(body[body.startIndex]) << 8 | Int(body[body.startIndex + 1])
        var start = body.startIndex + 2 + tlen
        if (type >> 1) & 3 > 0 { start += 2 }
        guard start <= body.endIndex,
              let json = try? JSONSerialization.jsonObject(with: body[start...]) as? [String: Any],
              let p = json["print"] as? [String: Any], p["command"] as? String == "push_status" else { return }
        lock.withLock { report.merge(p) { _, new in new } }
    }

    public func publish(_ payload: [String: Any]) async throws {
        guard let s = sock else { throw Stop("not connected", .unreachable) }
        let json = try JSONSerialization.data(withJSONObject: payload)
        try await s.send(packet(0x30, mqttString(topic) + json))
    }

    public func command(_ cmd: String, _ param: String = "") async throws {
        try await publish(["print": ["sequence_id": "0", "command": cmd, "param": param]])
    }

    public func status(fresh: Bool = true, wait: Double = 6) async throws -> Report {
        if fresh {
            lock.withLock { report.removeAll() }
            try await publish(["pushing": ["sequence_id": "0", "command": "pushall"]])
        }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let ready = lock.withLock { report["gcode_state"] != nil }
            if ready { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return lock.withLock { Report(report) }
    }

    public func waitFor(seconds: Double = 20, _ test: (Report) -> Bool) async throws -> Report {
        let deadline = Date().addingTimeInterval(seconds)
        var r = Report([:])
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            r = try await status(wait: 3)
            if test(r) { break }
        }
        return r
    }
}

func mqttString(_ s: String) -> Data {
    let b = Data(s.utf8)
    return Data([UInt8(b.count >> 8), UInt8(b.count & 0xFF)]) + b
}

func packet(_ type: UInt8, _ body: Data) -> Data {
    var out = Data([type])
    var n = body.count
    repeat {
        var byte = UInt8(n % 128)
        n /= 128
        if n > 0 { byte |= 0x80 }
        out.append(byte)
    } while n > 0
    return out + body
}

public let busyStates: Set<String> = ["RUNNING", "PREPARE", "PAUSE"]
public let speeds: [(String, Int)] = [("silent", 1), ("standard", 2), ("sport", 3), ("ludicrous", 4)]
public let speedNames = [1: "silent (50%)", 2: "standard (100%)", 3: "sport (124%)", 4: "ludicrous (166%)"]

public struct Report {
    public let raw: [String: Any]
    public init(_ raw: [String: Any]) { self.raw = raw }

    public func str(_ k: String) -> String? {
        switch raw[k] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    public func num(_ k: String) -> Double? { str(k).flatMap(Double.init) }
    public func int(_ k: String) -> Int? { num(k).map { Int($0) } }
    public func temp(_ k: String) -> Int { Int((num(k) ?? 0).rounded()) }

    public var state: String? { str("gcode_state") }
    public var busy: Bool { busyStates.contains(state ?? "") }
    public var job: String { str("subtask_name") ?? "" }

    public var spools: [(String, String)] {
        var out = [("external", ((raw["vt_tray"] as? [String: Any])?["tray_type"] as? String) ?? "")]
        let units = ((raw["ams"] as? [String: Any])?["ams"] as? [[String: Any]]) ?? []
        for unit in units {
            for tray in unit["tray"] as? [[String: Any]] ?? [] {
                let id = Int(tray["id"] as? String ?? "") ?? 0
                out.append(("AMS slot \(id + 1)", tray["tray_type"] as? String ?? ""))
            }
        }
        return out
    }

    public func spool(slot: Int?) -> String {
        let key = slot.map { "AMS slot \($0)" } ?? "external"
        return spools.first { $0.0 == key }?.1 ?? ""
    }

    public var hms: [String] {
        (raw["hms"] as? [[String: Any]] ?? []).map { h in
            let a = (h["attr"] as? NSNumber)?.uint32Value ?? 0, c = (h["code"] as? NSNumber)?.uint32Value ?? 0
            return String(format: "HMS_%04X_%04X_%04X_%04X", a >> 16, a & 0xFFFF, c >> 16, c & 0xFFFF)
        }
    }

    public var error: String? {
        let e = UInt32(truncatingIfNeeded: int("print_error") ?? 0)
        return e == 0 ? nil : String(format: "%04X_%04X", e >> 16, e & 0xFFFF)
    }

    public var alerts: [String] { hms + (error.map { [$0] } ?? []) }

    public var eta: String {
        guard let m = int("mc_remaining_time") else { return "?" }
        let done = timeOfDay(Date().addingTimeInterval(Double(m) * 60))
        return m >= 60 ? String(format: "%dh %02dm left, done at %@", m / 60, m % 60, done) : "\(m)m left, done at \(done)"
    }

    public var nozzle: String { "\(temp("nozzle_temper"))/\(temp("nozzle_target_temper"))C" }
    public var bed: String { "\(temp("bed_temper"))/\(temp("bed_target_temper"))C" }
    public var speed: String { speedNames[int("spd_lvl") ?? 0] ?? "" }

    public var describe: String {
        guard let s = state else { return "No status received. Is Developer Mode on?" }
        func row(_ k: String, _ v: String) -> String { "  " + k.padding(toLength: 13, withPad: " ", startingAt: 0) + v }
        var lines = [row("state", s)]
        if !job.isEmpty { lines.append(row("job", job)) }
        if busy {
            lines.append(row("progress", "\(str("mc_percent") ?? "?")%  (\(eta))"))
            lines.append(row("layer", "\(str("layer_num") ?? "?")/\(str("total_layer_num") ?? "?")"))
        }
        lines.append(row("nozzle", "\(temp("nozzle_temper")) / \(temp("nozzle_target_temper")) C  (\(str("nozzle_diameter") ?? "?")mm)"))
        lines.append(row("bed", "\(temp("bed_temper")) / \(temp("bed_target_temper")) C"))
        if busy, !speed.isEmpty { lines.append(row("speed", speed)) }
        for (k, v) in spools { lines.append(row(k, v.isEmpty ? "(not set)" : v)) }
        if let e = error { lines.append(row("error", e)) }
        for h in hms { lines.append(row("health", h)) }
        if let w = str("wifi_signal") { lines.append(row("wifi", w)) }
        return lines.joined(separator: "\n")
    }

}
