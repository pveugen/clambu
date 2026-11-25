import ArgumentParser
import ClambuCore
import Foundation

struct Materials: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List material presets for your printer.")
    @OptionGroup var printer: PrinterOption
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let cfg = try printer.config()
        var list: [[String: Any]] = []
        say("  For the \(cfg.machine.profile)\(cfg.material.map { ", default \($0)" } ?? "")\n")
        for m in try materials() {
            let plate = m.plate ?? cfg.plate ?? defaultPlate
            guard let profile = try? resolveProfile("filament", m.profile, for: cfg.machine) else {
                list.append(["name": m.name, "profile": m.profile, "available": false])
                say("  \(m.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(m.profile) (no profile for this printer)")
                continue
            }
            var d = try loadProfile("filament", profile)
            d.merge(m.overrides) { _, new in new }
            let noz = (d["nozzle_temperature"] as? [String])?.first ?? "?"
            let bed = (d[plateKeys[plate] ?? ""] as? [String])?.first ?? "?"
            list.append(["name": m.name, "profile": profile, "available": true, "plate": plate, "nozzle": Int(noz) ?? noz, "bed": Int(bed) ?? bed])
            say("  \(m.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(profile.padding(toLength: 34, withPad: " ", startingAt: 0)) \(noz) C nozzle, \(plate) \(bed) C")
        }
        say("\n  Add your own in \(Paths.materials)")
        try Output.done(["materials": list, "file": Paths.materials, "machine": cfg.machine.profile, "default": cfg.material ?? "pla"])
    }
}

struct Slice: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Slice STLs into a printable .3mf for your printer, then self-check it.")
    @OptionGroup var opts: SliceOptions
    @OptionGroup var printer: PrinterOption
    @OptionGroup var out: JSONFlag
    func run() async throws {
        _ = try await opts.slice(for: try printer.config())
        try Output.done()
    }
}

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Self-check a sliced .3mf.")
    @Argument var file: String
    @Option var plate = 1
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let (info, problems) = checkGCode(try readPlateGCode(file, plate: plate))
        if !out.json { printCheck(info, problems) }
        try Output.done(["file": file, "plate": plate, "info": JSON.object(info), "problems": problems], ok: problems.isEmpty)
    }
}

extension SliceOptions {
    func slice(for cfg: PrinterConfig) async throws -> String {
        let machine = cfg.machine
        let name = material ?? cfg.material ?? "pla"
        let m = try ClambuCore.material(name)
        let heights = layerProfiles(for: machine)
        let height = layer ?? defaultLayer(for: machine) ?? "0.20"
        guard let process = heights.first(where: { Double($0.height) == Double(height) })?.profile else {
            throw Stop("the \(machine.profile) has layer heights \(heights.map(\.height).joined(separator: ", "))", .usage)
        }
        let bed = plate ?? m.plate ?? cfg.plate ?? defaultPlate
        if plateKeys[bed] == nil { throw Stop("plate must be one of \(plateKeys.keys.sorted().joined(separator: ", "))", .usage) }
        let out = URL(fileURLWithPath: output ?? defaultOutput(stl, name)).standardizedFileURL.path
        say("Slicing \(stl.count) part(s) for the \(machine.printerModel) (\(machine.nozzle)mm) in \(name) at \(height)mm on the \(bed)")
        let warnings = try ClambuCore.slice(stl, material: m, machine: machine, out: out,
                                            SliceSettings(process: process, walls: walls, infill: infill, supports: supports, plate: bed))
        say("Sliced  \(out)")
        let (info, problems) = checkGCode(try readPlateGCode(out))
        let all = problems + warnings.map { "slicer: \($0)" }
        printCheck(info, all)
        Output.context["output"] = out
        Output.context["check"] = ["info": JSON.object(info), "problems": all]
        Output.context["warnings"] = warnings
        if !all.isEmpty { throw Stop("this file is not safe to print; nothing was sent") }
        return out
    }
}
