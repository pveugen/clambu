import Foundation

func hasDisplay() -> Bool {
    var st = stat()
    return stat("/dev/console", &st) == 0 && st.st_uid != 0
}

public func defaultOutput(_ stls: [String], _ material: String) -> String {
    let first = URL(fileURLWithPath: stls[0]).standardizedFileURL
    var stem = first.deletingPathExtension().lastPathComponent
    if stls.count > 1 { stem += "_plus\(stls.count - 1)" }
    return first.deletingLastPathComponent().appendingPathComponent("\(stem)_\(material).gcode.3mf").path
}

func packageGCode(_ gcode: String, into out: String) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clambu-pkg-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let files: [String: String] = [
        "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/><Default Extension="gcode" ContentType="text/x.gcode"/></Types>
            """,
        "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
            """,
        "3D/3dmodel.model": """
            <?xml version="1.0" encoding="UTF-8"?>
            <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources/><build/></model>
            """,
    ]
    for (name, body) in files {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
    let raw = try Data(contentsOf: URL(fileURLWithPath: gcode))
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Metadata"), withIntermediateDirectories: true)
    try raw.write(to: dir.appendingPathComponent("Metadata/plate_1.gcode"))
    try md5(raw).uppercased().write(to: dir.appendingPathComponent("Metadata/plate_1.gcode.md5"), atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(atPath: out)
    let r = try run("/usr/bin/zip", ["-q", "-X", "-r", out, "[Content_Types].xml", "_rels", "3D", "Metadata"], cwd: dir.path)
    if r.code != 0 { throw Stop("zip failed: \(r.err)") }
}

public struct SliceSettings {
    public var process: String, walls: Int, infill: Int, supports: Bool, plate: String
    public init(process: String, walls: Int, infill: Int, supports: Bool, plate: String) {
        self.process = process; self.walls = walls; self.infill = infill; self.supports = supports; self.plate = plate
    }
}

public func slice(_ stls: [String], material m: Material, machine: Machine, out: String, _ set: SliceSettings) throws -> [String] {
    guard FileManager.default.fileExists(atPath: Paths.studio) else { throw Stop("Bambu Studio not found at \(Paths.studio)", .setup) }
    for s in stls where !FileManager.default.fileExists(atPath: s) { throw Stop("no such file: \(s)", .usage) }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clambu-slice-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp.appendingPathComponent("out"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    var printer = try loadProfile("machine", machine.profile)
    var process = try loadProfile("process", set.process)
    var filament = try loadProfile("filament", try resolveProfile("filament", m.profile, for: machine))
    filament.merge(m.overrides) { _, new in new }
    process.merge(["wall_loops": "\(set.walls)", "sparse_infill_density": "\(set.infill)%",
                   "enable_support": set.supports ? "1" : "0", "curr_bed_type": set.plate]) { _, new in new }
    for (kind, var d) in [("machine", printer), ("process", process), ("filament", filament)] {
        d.removeValue(forKey: "inherits")
        d["from"] = "system"
        try JSONSerialization.data(withJSONObject: d).write(to: tmp.appendingPathComponent("\(kind).json"))
    }
    printer = [:]; process = [:]; filament = [:]

    let headless = !hasDisplay()
    var args = ["--debug", "3", "--arrange", "1", "--orient", "0", "--slice", "0",
                "--load-settings", "machine.json;process.json", "--load-filaments", "filament.json"]
    args += headless ? ["--outputdir", tmp.appendingPathComponent("out").path] : ["--export-3mf", out]
    args += stls.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    try? FileManager.default.removeItem(atPath: out)
    let r = try run(Paths.studio, args, cwd: tmp.path, timeout: 600)
    let log = String(decoding: r.out, as: UTF8.self) + r.err
    let plate1 = tmp.appendingPathComponent("out/plate_1.gcode").path
    if headless && r.code == 0 && FileManager.default.fileExists(atPath: plate1) {
        try packageGCode(plate1, into: out)
        say("  (no display: sliced to G-code and packaged it, without thumbnails)")
    }
    if r.code != 0 || !FileManager.default.fileExists(atPath: out) || log.range(of: "export.*failed", options: [.regularExpression, .caseInsensitive]) != nil {
        let lines = log.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("failed") }
        say(lines.suffix(8).joined(separator: "\n"))
        throw Stop("slicing or export failed")
    }
    return log.split(separator: "\n").compactMap { line in
        line.range(of: "slicing warnings: ").map { String(line[$0.upperBound...]) }
    }
}
