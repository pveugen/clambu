import Foundation

public enum Exit: Int32, Sendable, CaseIterable {
    case ok = 0
    case refused = 1
    case usage = 2
    case unreachable = 3
    case wrongState = 4
    case cancelled = 5
    case setup = 6

    public var name: String {
        switch self {
        case .ok: "ok"
        case .refused: "refused"
        case .usage: "usage"
        case .unreachable: "unreachable"
        case .wrongState: "wrong_state"
        case .cancelled: "cancelled"
        case .setup: "setup"
        }
    }
}

public struct Stop: Error, CustomStringConvertible {
    public let message: String
    public let exit: Exit
    public init(_ message: String, _ exit: Exit = .refused) { self.message = message; self.exit = exit }
    public var description: String { message }
}

public enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    public static let printerDir = home + "/.config/bambu"
    public static let clambuDir = home + "/.config/clambu"
    public static let materials = clambuDir + "/materials.toml"
    public static let plate = clambuDir + "/plate"
    public static let snaps = home + "/Pictures/clambu"
    public static let cache = home + "/.cache/clambu"
    public static let studio = "/Applications/BambuStudio.app/Contents/MacOS/BambuStudio"
    public static let profiles = "/Applications/BambuStudio.app/Contents/Resources/profiles/BBL"
}

public struct Machine: Sendable, Equatable {
    public var model: String
    public var nozzle: String
    public init(model: String, nozzle: String = "0.4") { self.model = model; self.nozzle = nozzle }
    public var profile: String { "Bambu Lab \(model) \(nozzle) nozzle" }
    public var printerModel: String { "Bambu Lab \(model)" }
    public var hasCamera: Bool { ["A1", "A1 mini", "A2L", "P1P", "P1S"].contains(model) }

    public static let serialPrefixes: [(String, String)] = [
        ("030", "A1 mini"), ("039", "A1"), ("26A", "A2L"), ("01S", "P1P"), ("01P", "P1S"), ("22E", "P2S"),
        ("00M", "X1 Carbon"), ("03W", "X1E"), ("20P", "X2D"), ("094", "H2D"), ("239", "H2D Pro"),
        ("093", "H2S"), ("31B", "H2C"), ("32X", "H3C"),
    ]

    public static func guess(serial: String) -> String? {
        serialPrefixes.first { serial.uppercased().hasPrefix($0.0) }?.1
    }

    public static func models() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.profiles + "/machine")) ?? []
        let found = names.compactMap { name -> String? in
            guard name.hasPrefix("Bambu Lab "), name.hasSuffix(" 0.4 nozzle.json") else { return nil }
            return String(name.dropFirst("Bambu Lab ".count).dropLast(" 0.4 nozzle.json".count))
        }
        return found.isEmpty ? serialPrefixes.map(\.1) : found.sorted()
    }
}

public let plateKeys: [String: String] = [
    "Textured PEI Plate": "textured_plate_temp_initial_layer",
    "Cool Plate": "cool_plate_temp_initial_layer",
    "Engineering Plate": "eng_plate_temp_initial_layer",
    "High Temp Plate": "hot_plate_temp_initial_layer",
]

public let defaultPlate = "Textured PEI Plate"

public struct Material {
    public var name: String
    public var profile: String
    public var plate: String?
    public var nozzle: Int?
    public var overrides: [String: Any] {
        guard let n = nozzle else { return [:] }
        return ["nozzle_temperature": ["\(n)"], "nozzle_temperature_initial_layer": ["\(n)"]]
    }
}

public func materials() throws -> [Material] {
    var list = [
        Material(name: "pla", profile: "Bambu PLA Basic"),
        Material(name: "polyterra", profile: "PolyTerra PLA"),
        Material(name: "pla-generic", profile: "Generic PLA"),
        // 260 C instead of Bambu's 255 C: on an A1 mini at sport speed, 255 C made the extruder click.
        Material(name: "petg", profile: "Generic PETG", nozzle: 260),
    ]
    guard let text = try? String(contentsOfFile: Paths.materials, encoding: .utf8) else { return list }
    for (name, kv) in try parseTOML(text) {
        var m = list.first { $0.name == name } ?? Material(name: name, profile: "")
        if let v = kv["profile"] { m.profile = v }
        if let v = kv["plate"] { m.plate = v }
        if let v = kv["nozzle"] { m.nozzle = Int(v) }
        guard !m.profile.isEmpty else { throw Stop("\(Paths.materials): [\(name)] needs a profile", .setup) }
        if let i = list.firstIndex(where: { $0.name == name }) { list[i] = m } else { list.append(m) }
    }
    return list
}

public func material(_ name: String) throws -> Material {
    let all = try materials()
    guard let m = all.first(where: { $0.name == name }) else {
        throw Stop("unknown material '\(name)'. Choose from: \(all.map(\.name).joined(separator: ", "))", .usage)
    }
    return m
}

func parseTOML(_ text: String) throws -> [(String, [String: String])] {
    var out: [(String, [String: String])] = []
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("[") {
            guard let end = line.firstIndex(of: "]") else { throw Stop("\(Paths.materials): cannot read '\(line)'", .setup) }
            out.append((line[line.index(after: line.startIndex)..<end].trimmingCharacters(in: .whitespaces), [:]))
        } else if let eq = line.firstIndex(of: "="), !out.isEmpty {
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            var rest = Substring(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            let v: String
            if let q = rest.first, q == "\"" || q == "'" {
                rest = rest.dropFirst()
                guard let close = rest.firstIndex(of: q) else { throw Stop("\(Paths.materials): unclosed quote in '\(line)'", .setup) }
                v = String(rest[..<close])
            } else {
                v = String(rest.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
            }
            out[out.count - 1].1[k] = v
        } else {
            throw Stop("\(Paths.materials): cannot read '\(line)'", .setup)
        }
    }
    return out
}

public struct PrinterConfig {
    public let name: String
    public let path: String
    public let ip: String
    public let serial: String
    let accessCode: String
    public let machine: Machine
    public let material: String?
    public let plate: String?

    public init(name: String, path: String, ip: String, serial: String, accessCode: String, machine: Machine,
                material: String? = nil, plate: String? = nil) {
        self.name = name; self.path = path; self.ip = ip; self.serial = serial; self.accessCode = accessCode
        self.machine = machine; self.material = material; self.plate = plate
    }

    public static func path(_ name: String) -> String { "\(Paths.printerDir)/\(name).env" }

    public static func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.printerDir)) ?? []
        return files.filter { $0.hasSuffix(".env") }.map { String($0.dropLast(4)) }.sorted()
    }

    public static func defaultName() -> String {
        if let env = ProcessInfo.processInfo.environment["CLAMBU_PRINTER"], !env.isEmpty { return env }
        let all = names()
        return all.count == 1 ? all[0] : "printer"
    }

    public static func load(_ name: String) throws -> PrinterConfig {
        let path = path(name)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            let others = names()
            throw Stop(others.isEmpty || others == [name]
                ? "no printer set up yet; run: clambu setup"
                : "no printer config at \(path); pick one with --printer: \(others.joined(separator: ", "))", .setup)
        }
        if !isPrivate(path) {
            FileHandle.standardError.write("warning: \(path) is readable by other users; run: chmod 600 \(path)\n".data(using: .utf8)!)
        }
        let kv = parseEnv(text)
        let missing = ["PRINTER_IP", "PRINTER_SERIAL", "PRINTER_ACCESS_CODE"].filter { (kv[$0] ?? "").isEmpty }
        if !missing.isEmpty { throw Stop("missing in \(path): \(missing.joined(separator: ", ")); run: clambu setup", .setup) }
        let serial = kv["PRINTER_SERIAL"]!
        guard let model = kv["PRINTER_MODEL"].flatMap({ $0.isEmpty ? nil : $0 }) ?? Machine.guess(serial: serial) else {
            throw Stop("set PRINTER_MODEL in \(path), for example PRINTER_MODEL=\"P1S\"", .setup)
        }
        return PrinterConfig(name: name, path: path, ip: kv["PRINTER_IP"]!, serial: serial, accessCode: kv["PRINTER_ACCESS_CODE"]!,
                             machine: Machine(model: model, nozzle: kv["PRINTER_NOZZLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "0.4"),
                             material: kv["MATERIAL"].flatMap { $0.isEmpty ? nil : $0 },
                             plate: kv["PLATE"].flatMap { $0.isEmpty ? nil : $0 })
    }

    public static func write(name: String, ip: String, serial: String, accessCode: String, machine: Machine,
                             material: String, plate: String) throws -> String {
        let path = path(name)
        try FileManager.default.createDirectory(atPath: Paths.printerDir, withIntermediateDirectories: true)
        let text = """
            PRINTER_IP=\(ip)
            PRINTER_SERIAL=\(serial)
            PRINTER_ACCESS_CODE=\(accessCode)
            PRINTER_MODEL="\(machine.model)"
            PRINTER_NOZZLE=\(machine.nozzle)
            MATERIAL=\(material)
            PLATE="\(plate)"

            """
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        try text.write(toFile: path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    static func parseEnv(_ text: String) -> [String: String] {
        var kv: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
            kv[k] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return kv
    }

    public static func isPrivate(_ path: String) -> Bool {
        let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
        return mode & 0o077 == 0
    }
}
