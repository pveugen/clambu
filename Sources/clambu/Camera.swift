import ArgumentParser
import ClambuCore
import Foundation

struct PlateCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plate", abstract: "Is the build plate clear? Camera plus Eye.",
                                                    discussion: "Actions: check (default), learn, forget.")
    @Argument var action = "check"
    @Flag(help: "learn: this frame has parts on the plate.") var busy = false
    @Flag(help: "learn: home the printer and keep the empty plate every 10mm of bed travel (about 3 minutes).") var sweep = false
    @Option(help: "check: judge this image instead of a fresh frame.") var image: String?
    @Flag(name: .shortAndLong) var yes = false
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption

    func run() async throws {
        switch action {
        case "check": try await check()
        case "learn": try await learn()
        case "forget": try forget()
        default: throw Stop("plate action must be check, learn or forget", .usage)
        }
    }

    var references: [String: Int] { ["empty": Plate.count("empty"), "busy": Plate.count("busy")] }

    func check() async throws {
        let frame: String
        if let image { frame = image } else { frame = try await saveSnap(try printer.config(), "plate") }
        let v = try await Plate.judge(frame)
        if !out.json {
            say("  plate        \(v.verdict)")
            say("  why          \(v.why)")
            if !v.tiles.isEmpty { say("  tiles        " + v.tiles.map { String(format: "%.3f", $0) }.joined(separator: " ")) }
            say("  frame        \(frame)")
            say("  references   \(Plate.count("empty")) empty, \(Plate.count("busy")) busy")
        }
        var d: [String: Any] = ["verdict": v.verdict, "why": v.why, "tiles": v.tiles, "frame": frame, "references": references]
        if let e = v.empty { d["empty"] = e }
        if let t = v.tile { d["tile"] = t }
        if let b = v.busy { d["busy"] = b }
        try Output.done(d, ok: v.verdict == "clear")
    }

    func learn() async throws {
        let cfg = try printer.config()
        let kind = busy ? "busy" : "empty"
        let r = try await withPrinter(cfg) { try await $0.status() }
        if r.busy { throw Stop("the printer is \(r.state ?? "busy"); learn the plate while it's idle", .wrongState) }
        let frame = try await saveSnap(cfg, "plate-\(kind)")
        say("   Frame: \(frame)")
        try confirm("Is the plate \(busy ? "covered" : "clear") in this frame?", yes)
        var kept = [try await Plate.remember(frame, kind)]
        say("Kept \(kept[0]) as a\(busy ? "" : "n") \(kind) plate reference")
        if sweep && !busy { kept += try await sweepEmpty(cfg) }
        say("References: \(Plate.count("empty")) empty, \(Plate.count("busy")) busy")
        try Output.done(["kept": kept, "references": references])
    }

    func sweepEmpty(_ cfg: PrinterConfig) async throws -> [String] {
        try confirm("Home the printer and keep the empty plate at 19 bed positions, every 10mm?", yes)
        return try await withPrinter(cfg) { p in
            try await p.command("gcode_line", "G28\n")
            say("   homing")
            try await Task.sleep(nanoseconds: 75_000_000_000)
            try await p.command("gcode_line", "G90\nG1 Z60 F1200\n")
            try await Task.sleep(nanoseconds: 8_000_000_000)
            var kept: [String] = []
            for y in stride(from: 0, through: 180, by: 10) {
                try await p.command("gcode_line", "G1 Y\(y) F3000\n")
                try await Task.sleep(nanoseconds: 6_000_000_000)
                let k = try await Plate.remember(try await saveSnap(cfg, "plate-empty-y\(y)"), "empty")
                kept.append(k)
                say("Kept \(k) (bed at Y\(y))")
            }
            return kept
        }
    }

    func forget() throws {
        try confirm("Delete every plate reference in \(Paths.plate)?", yes)
        try? FileManager.default.removeItem(atPath: Paths.plate)
        say("Plate references deleted")
        try Output.done()
    }
}

struct Cam: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save the sharpest of a few camera frames (default to ~/Pictures/clambu).")
    @Option(name: .shortAndLong) var output: String?
    @Option(help: "Keep the sharpest of this many frames in a row, by Eye. The camera sends one about every 2.4s; 1 takes the first.")
    var frames = 5
    @Flag(help: "Open it in Preview.") var open = false
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        let cfg = try printer.config()
        guard (1...20).contains(frames) else { throw Stop("--frames must be 1-20", .usage) }
        let pick = try await sharpSnapshot(cfg, count: frames)
        let path: String
        if let output {
            path = URL(fileURLWithPath: output).standardizedFileURL.path
        } else {
            try FileManager.default.createDirectory(atPath: Paths.snaps, withIntermediateDirectories: true)
            path = "\(Paths.snaps)/\(timestamp())-cam.jpg"
        }
        try pick.frame.write(to: URL(fileURLWithPath: path))
        if !out.json { say(path + (pick.scores.isEmpty ? "" : String(format: "  (sharpest of %d, %.2f)", pick.scores.count, pick.score))) }
        if open { _ = try ClambuCore.run("/usr/bin/open", [path], timeout: 10) }
        var d: [String: Any] = ["path": path]
        if !pick.scores.isEmpty { d["sharpness"] = pick.score; d["scores"] = pick.scores }
        try Output.done(d)
    }
}
