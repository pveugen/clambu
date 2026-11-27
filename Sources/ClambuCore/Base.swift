import Foundation

public struct BaseLayer: Equatable, Sendable {
    public var z: Double
    public var area: Double
}

public func objectBases(_ text: String, depth: Double = 2) -> [Int: [BaseLayer]] {
    var width = 0.4
    var bases: [Int: [BaseLayer]] = [:]
    var z = 0.0, firstZ: Double?
    var x = 0.0, y = 0.0, relative = false
    var object: Int?
    var path: [Int: Double] = [:]

    func close() {
        for (id, length) in path { bases[id, default: []].append(BaseLayer(z: z, area: length * width)) }
        path = [:]
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        if line.hasPrefix(";") {
            if line.hasPrefix("; CHANGE_LAYER") {
                close()
                if let f = firstZ, z > f + depth { break }
            } else if line.hasPrefix("; Z_HEIGHT: ") {
                z = Double(line.dropFirst(12).trimmingCharacters(in: .whitespaces)) ?? z
                if firstZ == nil { firstZ = z }
            } else if line.hasPrefix("; start printing object, unique label id:") {
                object = line.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            } else if line.hasPrefix("; stop printing object") {
                object = nil
            } else if line.hasPrefix("; nozzle_diameter = ") {
                width = Double(first(String(line.dropFirst(20)))) ?? width
            }
            continue
        }
        if line.hasPrefix("G90") { relative = false; continue }
        if line.hasPrefix("G91") { relative = true; continue }
        guard line.hasPrefix("G0 ") || line.hasPrefix("G1 ") || line.hasPrefix("G2 ") || line.hasPrefix("G3 ") else { continue }
        var nx = relative ? 0.0 : x, ny = relative ? 0.0 : y, e = 0.0
        for word in (line.split(separator: ";", maxSplits: 1).first ?? line).split(separator: " ") {
            guard let v = Double(word.dropFirst()) else { continue }
            switch word.first {
            case "X": nx = v
            case "Y": ny = v
            case "E": e = v
            default: break
            }
        }
        if relative { nx += x; ny += y }
        if e > 0, firstZ != nil { path[object ?? unlabeled, default: 0] += hypot(nx - x, ny - y) }
        x = nx; y = ny
    }
    close()
    let labeled = bases.keys.contains { $0 != unlabeled }
    return labeled ? bases.filter { $0.key != unlabeled } : bases
}

public let unlabeled = -1

func objectName(_ id: Int, _ names: [Int: String]) -> String {
    if id == unlabeled { return "the model" }
    return names[id] ?? "object \(id)"
}

public func floatingBases(_ text: String, names: [Int: String] = [:]) -> [String] {
    objectBases(text).sorted { $0.key < $1.key }.compactMap { id, layers in
        guard var below = layers.first?.area else { return nil }
        for layer in layers.dropFirst() {
            if layer.area > 5 * below && layer.area - below > 50 {
                let name = objectName(id, names)
                let start = String(format: "%.1fmm² on the plate at %.2fmm", layers[0].area, layers[0].z)
                return "\(name) prints its base in the air: \(start), then about \(String(format: "%.0f", layer.area))mm² at "
                    + "\(String(format: "%.2f", layer.z))mm. Look for thin bits poking out of the bottom of the model."
            }
            below = max(below, layer.area)
        }
        return nil
    }
}

public func objectNames(_ path: String) -> [Int: String] {
    guard let r = try? run("/usr/bin/unzip", ["-p", path, "Metadata/model_settings.config"], timeout: 30), r.code == 0 else { return [:] }
    let xml = String(decoding: r.out, as: UTF8.self)
    var objectName: [String: String] = [:]
    var current: String?
    var names: [Int: String] = [:]
    var instanceObject: String?
    for raw in xml.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("<object id=\"") { current = attribute(line, "id") }
        if line.hasPrefix("</object>") { current = nil }
        if let c = current, objectName[c] == nil, line.contains("key=\"name\"") { objectName[c] = attribute(line, "value") }
        if line.contains("key=\"object_id\"") { instanceObject = attribute(line, "value") }
        if line.contains("key=\"identify_id\""), let o = instanceObject, let id = attribute(line, "value").flatMap(Int.init) {
            names[id] = objectName[o]
        }
    }
    return names
}

func attribute(_ line: String, _ name: String) -> String? {
    guard let start = line.range(of: "\(name)=\"") else { return nil }
    return String(line[start.upperBound...].prefix { $0 != "\"" })
}

public func footprintHints(_ path: String, plate: Int = 1) -> [String] {
    guard let r = try? run("/usr/bin/unzip", ["-p", path, "Metadata/plate_\(plate).json"], timeout: 30), r.code == 0,
          let d = try? JSONSerialization.jsonObject(with: r.out) as? [String: Any],
          let objects = d["bbox_objects"] as? [[String: Any]] else { return [] }
    return objects.compactMap { o in
        guard let area = o["area"] as? Double, let b = o["bbox"] as? [Double], b.count == 4 else { return nil }
        let box = (b[2] - b[0]) * (b[3] - b[1])
        guard box > 25, area < 0.05 * box else { return nil }
        let name = o["name"] as? String ?? "an object"
        return "\(name) touches the plate with only \(String(format: "%.1f", area))mm² of its \(String(format: "%.0f", box))mm² footprint"
    }
}
