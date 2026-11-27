import CryptoKit
import Foundation

public func loadProfile(_ kind: String, _ name: String) throws -> [String: Any] {
    let path = "\(Paths.profiles)/\(kind)/\(name).json"
    guard let data = FileManager.default.contents(atPath: path),
          var d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw Stop("unknown \(kind) profile: \(name)", .setup)
    }
    if let parent = d["inherits"] as? String, !parent.isEmpty {
        var base = try loadProfile(kind, parent)
        base.merge(d) { _, new in new }
        d = base
    }
    let includes = d.removeValue(forKey: "include") as? [String] ?? []
    for inc in includes {
        guard let data = FileManager.default.contents(atPath: "\(Paths.profiles)/\(kind)/\(inc).json"),
              let part = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        for (k, v) in part where !["name", "instantiation", "type", "from", "inherits", "setting_id"].contains(k) {
            d[k] = v
        }
    }
    return d
}

func rawProfile(_ kind: String, _ name: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: "\(Paths.profiles)/\(kind)/\(name).json") else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func fits(_ d: [String: Any], _ machine: Machine) -> Bool {
    (d["instantiation"] as? String) != "false" && ((d["compatible_printers"] as? [String]) ?? []).contains(machine.profile)
}

func profileNames(_ kind: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "\(Paths.profiles)/\(kind)")) ?? [])
        .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
}

public func resolveProfile(_ kind: String, _ name: String, for machine: Machine) throws -> String {
    if let d = rawProfile(kind, name), fits(d, machine) || ((d["compatible_printers"] as? [String]) ?? []).isEmpty { return name }
    let base = name.range(of: " @BBL").map { String(name[..<$0.lowerBound]) } ?? name
    let hits = profileNames(kind).filter { $0.hasPrefix(base + " @BBL") && rawProfile(kind, $0).map { fits($0, machine) } == true }
    guard let hit = hits.min(by: { $0.count < $1.count }) else {
        throw Stop("Bambu Studio has no \(kind) profile '\(base)' for the \(machine.profile)", .setup)
    }
    return hit
}

public func layerProfiles(for machine: Machine) -> [(height: String, profile: String)] {
    let plain: Set = ["Standard", "Fine", "Optimal", "Draft", "Extra Fine", "Extra Draft", "Super Draft"]
    var best: [String: (rank: Int, name: String)] = [:]
    for name in profileNames("process") {
        guard let mm = name.range(of: "mm "), let at = name.range(of: " @BBL"), mm.upperBound <= at.lowerBound,
              let d = rawProfile("process", name), fits(d, machine) else { continue }
        let height = String(name[..<mm.lowerBound])
        let rank = plain.contains(String(name[mm.upperBound..<at.lowerBound])) ? 0 : 1
        if let b = best[height], (b.rank, b.name.count) <= (rank, name.count) { continue }
        best[height] = (rank, name)
    }
    return best.map { ($0.key, $0.value.name) }.sorted { (Double($0.0) ?? 0) < (Double($1.0) ?? 0) }
}

public func defaultLayer(for machine: Machine) -> String? {
    guard let d = try? loadProfile("machine", machine.profile), let p = d["default_print_profile"] as? String,
          let mm = p.range(of: "mm ") else { return nil }
    return String(p[..<mm.lowerBound])
}

public func readPlateGCode(_ path: String, plate: Int = 1) throws -> String {
    guard FileManager.default.fileExists(atPath: path) else { throw Stop("no such file: \(path)", .usage) }
    let entry = "Metadata/plate_\(plate).gcode"
    let r = try run("/usr/bin/unzip", ["-p", path, entry], timeout: 120)
    if r.code != 0 || r.out.isEmpty { throw Stop("\(path) has no sliced \(entry); slice it first", .usage) }
    return String(decoding: r.out, as: UTF8.self)
}

public func md5(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public struct CheckInfo: Codable {
    public var filament = "", profile = "", plate = "", nozzleDiameter = "", layerHeight = "", printer = ""
    public var nozzleFirstLayer: Int?, bedFirstLayer: Int?, layers: Int?
    public var time = "?", grams = "?"
}

func first(_ v: String?) -> String {
    guard let v else { return "" }
    return (v.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? "")
        .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

func num(_ v: String?, _ fallback: Int) -> Int {
    Double(first(v)).map { Int($0) } ?? fallback
}

func temps(_ lines: [Substring], _ commands: [String]) -> [Int] {
    lines.compactMap { line -> Int? in
        for c in commands where line.hasPrefix(c + " S") {
            return Int(line.dropFirst(c.count + 2).prefix { $0.isNumber })
        }
        return nil
    }
}

public func checkGCode(_ text: String, names: [Int: String] = [:]) -> (CheckInfo, [String]) {
    guard let change = text.range(of: "; CHANGE_LAYER") else { return (CheckInfo(), ["no layers found in the G-code"]) }
    var s: [String: String] = [:]
    var time: String?, grams: String?, layerCount: Int?
    for line in text.split(separator: "\n") where line.hasPrefix(";") {
        if line.hasPrefix("; "), let eq = line.range(of: " = ") {
            let key = line[line.index(line.startIndex, offsetBy: 2)..<eq.lowerBound]
            if !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "[" || $0 == "]" }), s[String(key)] == nil {
                s[String(key)] = String(line[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        if time == nil, let r = line.range(of: "total estimated time: ") {
            time = String(line[r.upperBound...].prefix { $0 != ";" }).trimmingCharacters(in: .whitespaces)
        }
        if grams == nil, let r = line.range(of: "total filament weight [g] : ") {
            grams = String(line[r.upperBound...].prefix { $0.isNumber || $0 == "." })
        }
        if layerCount == nil, line.hasPrefix("; total layer number: ") {
            layerCount = Int(line.dropFirst("; total layer number: ".count).prefix { $0.isNumber })
        }
    }
    let pre = text[..<change.lowerBound].split(separator: "\n").filter { !$0.hasPrefix(";") }.map {
        $0.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map {
            Substring($0.trimmingCharacters(in: .whitespaces))
        } ?? ""
    }
    let noz = temps(pre, ["M104", "M109"]), bed = temps(pre, ["M140", "M190"])
    let ftype = first(s["filament_type"])
    let wantNoz = num(s["nozzle_temperature_initial_layer"], 0)
    let lo = num(s["nozzle_temperature_range_low"], 0), hi = num(s["nozzle_temperature_range_high"], 999)
    let plate = first(s["curr_bed_type"])
    let wantBed = plateKeys[plate].map { num(s[$0], -1) }

    var info = CheckInfo()
    info.filament = ftype; info.profile = first(s["filament_settings_id"]); info.plate = plate
    info.nozzleFirstLayer = noz.last; info.bedFirstLayer = bed.last
    info.nozzleDiameter = first(s["nozzle_diameter"]); info.layerHeight = first(s["layer_height"])
    info.layers = layerCount; info.time = time ?? "?"; info.grams = grams ?? "?"
    info.printer = first(s["printer_model"])

    var problems: [String] = []
    if !info.printer.hasPrefix("Bambu Lab ") { problems.append("the file isn't sliced for a Bambu Lab printer") }
    if !hasOwnStart(text, s["machine_start_gcode"]) { problems.append("start G-code is not the \(info.printer)'s own (generic fallback routine)") }
    if let n = noz.last {
        if n != wantNoz { problems.append("nozzle is \(n) C for layer 1, but the \(ftype) profile wants \(wantNoz) C") }
        if !(lo...hi).contains(n) { problems.append("layer 1 nozzle \(n) C is outside \(ftype)'s safe range \(lo)-\(hi) C") }
    } else {
        problems.append("no nozzle temperature set before layer 1")
    }
    if let wantBed {
        if bed.last != wantBed {
            problems.append("bed is \(bed.last.map { "\($0)" } ?? "never set") C for layer 1, \(plate) with \(ftype) wants \(wantBed) C")
        }
    } else {
        problems.append("unknown plate type '\(plate)'")
    }
    if ftype.isEmpty { problems.append("filament type missing from the G-code") }
    problems += floatingBases(text, names: names)
    return (info, problems)
}

func hasOwnStart(_ text: String, _ setting: String?) -> Bool {
    guard let mark = setting?.components(separatedBy: "\\n").first(where: { $0.hasPrefix(";=====") }) else { return false }
    return text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == mark.trimmingCharacters(in: .whitespaces) }
}

public struct FileCheck {
    public var gcode: String
    public var info: CheckInfo
    public var problems: [String]
    public var warnings: [String]
}

public func checkFile(_ path: String, plate: Int = 1) throws -> FileCheck {
    let gcode = try readPlateGCode(path, plate: plate)
    let (info, problems) = checkGCode(gcode, names: objectNames(path))
    return FileCheck(gcode: gcode, info: info, problems: problems, warnings: footprintHints(path, plate: plate))
}

public func printCheck(_ i: CheckInfo, _ problems: [String], warnings: [String] = []) {
    say("  \(i.printer): \(i.profile) (\(i.filament)), \(i.plate)")
    say("  layer 1: nozzle \(i.nozzleFirstLayer.map { "\($0)" } ?? "?") C, bed \(i.bedFirstLayer.map { "\($0)" } ?? "?") C, "
        + "\(i.nozzleDiameter)mm nozzle, \(i.layerHeight)mm layers" + (i.layers.map { ", \($0) layers" } ?? ""))
    say("  \(i.time), \(i.grams)g")
    for w in warnings { say("  warn: \(w)") }
    for p in problems { say("  FAIL: \(p)") }
    if problems.isEmpty { say("  self-check passed") }
}
