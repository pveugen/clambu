import Foundation

public struct PrinterState: Codable, Equatable, Sendable {
    public var state: String?
    public var label: String
    public var busy: Bool
    public var job: String
    public var percent: Int?
    public var layer: Int?
    public var totalLayers: Int?
    public var remainingMinutes: Int?
    public var finishAt: Date?
    public var nozzle: Int
    public var nozzleTarget: Int
    public var bed: Int
    public var bedTarget: Int
    public var nozzleDiameter: String?
    public var speed: String?
    public var speedLevel: Int?
    public var spool: String
    public var spools: [Spool]
    public var alerts: [String]
    public var wifi: String?
    public var updatedAt: Date

    public struct Spool: Codable, Equatable, Sendable {
        public var slot: String
        public var material: String
    }

    public init(_ r: Report, at now: Date = Date()) {
        state = r.state
        label = PrinterState.label(r.state)
        busy = r.busy
        job = r.job
        if r.busy {
            percent = r.int("mc_percent")
            layer = r.int("layer_num")
            totalLayers = r.int("total_layer_num")
            remainingMinutes = r.int("mc_remaining_time")
            finishAt = remainingMinutes.map { now.addingTimeInterval(Double($0) * 60) }
        }
        nozzle = r.temp("nozzle_temper"); nozzleTarget = r.temp("nozzle_target_temper")
        bed = r.temp("bed_temper"); bedTarget = r.temp("bed_target_temper")
        nozzleDiameter = r.str("nozzle_diameter")
        speedLevel = r.int("spd_lvl")
        speed = speedLevel.flatMap { lvl in speeds.first { $0.1 == lvl }?.0 }
        spool = r.spool(slot: nil)
        spools = r.spools.map { Spool(slot: $0.0, material: $0.1) }
        alerts = r.alerts
        wifi = r.str("wifi_signal")
        updatedAt = now
    }

    public static let connecting = PrinterState(Report([:]))

    public static func label(_ state: String?) -> String {
        switch state {
        case nil: "connecting"
        case "RUNNING": "printing"
        case "PREPARE": "heating up"
        case "PAUSE": "paused"
        case "FINISH": "finished"
        case "FAILED": "failed"
        case "IDLE": "idle"
        case let s?: s.lowercased()
        }
    }

    public var remaining: String? {
        remainingMinutes.map { $0 >= 60 ? "\($0 / 60)h \(String(format: "%02d", $0 % 60))m" : "\($0)m" }
    }

    public var tone: Tone {
        if !alerts.isEmpty || state == "FAILED" { return .bad }
        switch state {
        case "RUNNING": return .good
        case "PREPARE": return .busy
        case "PAUSE": return .warn
        case "FINISH": return .done
        default: return .quiet
        }
    }

    public enum Tone: String, Codable, Sendable { case good, busy, warn, bad, done, quiet }
}

public struct History: Codable, Equatable, Sendable {
    public var nozzle: [Int] = []
    public var bed: [Int] = []
    public var percent: [Int] = []
    public static let keep = 120

    public init() {}

    public mutating func add(_ s: PrinterState) {
        guard s.state != nil else { return }
        nozzle.append(s.nozzle); bed.append(s.bed); percent.append(s.percent ?? 0)
        if nozzle.count > History.keep {
            nozzle.removeFirst(nozzle.count - History.keep)
            bed.removeFirst(bed.count - History.keep)
            percent.removeFirst(percent.count - History.keep)
        }
    }
}

public enum JSON {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func string<T: Encodable>(_ v: T, pretty: Bool = true) -> String {
        String(decoding: (try? encoder(pretty: pretty).encode(v)) ?? Data("{}".utf8), as: UTF8.self)
    }

    public static func object<T: Encodable>(_ v: T) -> Any {
        guard let d = try? encoder(pretty: false).encode(v) else { return [String: Any]() }
        return (try? JSONSerialization.jsonObject(with: d)) ?? [String: Any]()
    }

    public static func string(any v: Any, pretty: Bool = true) -> String {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        guard JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: opts) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

public enum Output {
    nonisolated(unsafe) public static var json = false

    public static func result(_ fields: [String: Any], ok: Bool = true) {
        var d = fields
        d["ok"] = ok
        print(JSON.string(any: d))
        fflush(stdout)
    }

    public static func failure(_ exit: Exit, _ message: String) {
        result(["error": ["code": exit.name, "exit": Int(exit.rawValue), "message": message]], ok: false)
    }
}

extension PrinterState {
    public var oneline: String {
        let now = timeOfDay()
        let s = (state ?? "?").padding(toLength: 8, withPad: " ", startingAt: 0)
        let temps = "nozzle \(nozzle)/\(nozzleTarget)C  bed \(bed)/\(bedTarget)C"
        guard busy else { return "\(now)  \(s) \(temps)" }
        let left = remaining.map { r in "\(r) left" + (finishAt.map { ", done at \(timeOfDay($0))" } ?? "") } ?? "?"
        return "\(now)  \(s) \(String(format: "%3d", percent ?? 0))%  layer \(layer.map(String.init) ?? "?")/\(totalLayers.map(String.init) ?? "?")  \(temps)  \(left)"
    }
}
