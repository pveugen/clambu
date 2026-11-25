import ArgumentParser
import ClambuCore
import Foundation

func needPrint(_ p: Printer, _ states: Set<String> = busyStates) async throws -> Report {
    let r = try await p.status()
    guard states.contains(r.state ?? "") else { throw Stop("no print running (\(r.state ?? "?"))", .wrongState) }
    return r
}

struct Pause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause the running print.")
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        let r = try await withPrinter(try printer.config()) { p in
            _ = try await needPrint(p, ["RUNNING", "PREPARE"])
            try await p.command("pause")
            return try await p.waitFor { $0.state == "PAUSE" }
        }
        if !out.json { say("Printer state: \(r.state ?? "?"). Resume with: clambu resume") }
        try Output.done(["status": JSON.object(PrinterState(r))], ok: r.state == "PAUSE", exit: .wrongState)
    }
}

struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume a paused print.")
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        let r = try await withPrinter(try printer.config()) { p in
            _ = try await needPrint(p, ["PAUSE"])
            try await p.command("resume")
            return try await p.waitFor { $0.state == "RUNNING" }
        }
        if !out.json { say("Printer state: \(r.state ?? "?")") }
        try Output.done(["status": JSON.object(PrinterState(r))], ok: r.state == "RUNNING", exit: .wrongState)
    }
}

struct StopCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop the running print (asks first).")
    @Flag(name: .shortAndLong) var yes = false
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        let after = try await withPrinter(try printer.config()) { p in
            let r = try await needPrint(p)
            say("   \(r.job.isEmpty ? "The print" : r.job) is at \(r.str("mc_percent") ?? "?")%, layer \(r.str("layer_num") ?? "?")/\(r.str("total_layer_num") ?? "?")")
            try confirm("Stop it? A stopped print can't be resumed.", yes)
            try await p.command("stop")
            return try await p.waitFor(seconds: 15) { !$0.busy }
        }
        if !out.json { say("Stop sent. Printer state: \(after.state ?? "?")") }
        try Output.done(["status": JSON.object(PrinterState(after))])
    }
}

struct Speed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Change speed of the running print: silent, standard, sport or ludicrous.")
    @Argument var mode: String
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        guard let level = speeds.first(where: { $0.0 == mode })?.1 else {
            throw Stop("speed must be one of \(speeds.map(\.0).joined(separator: ", "))", .usage)
        }
        let r = try await withPrinter(try printer.config()) { p in
            _ = try await needPrint(p)
            try await p.command("print_speed", "\(level)")
            return try await p.waitFor { $0.int("spd_lvl") == level }
        }
        if !out.json { say("Speed now \(r.speed), \(r.eta)") }
        try Output.done(["status": JSON.object(PrinterState(r))], ok: r.int("spd_lvl") == level, exit: .wrongState)
    }
}

struct Temp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Set the nozzle temperature of the running print, 180-280 C.")
    @Argument var celsius: Int
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        guard (180...280).contains(celsius) else { throw Stop("nozzle temperature must be 180-280 C", .usage) }
        let r = try await withPrinter(try printer.config()) { p in
            _ = try await needPrint(p, ["RUNNING", "PAUSE"])
            try await p.command("gcode_line", "M104 S\(celsius)\n")
            return try await p.waitFor { $0.int("nozzle_target_temper") == celsius }
        }
        if !out.json { say("Nozzle target now \(r.int("nozzle_target_temper") ?? 0) C (currently \(r.temp("nozzle_temper")) C), for this print only.") }
        try Output.done(["status": JSON.object(PrinterState(r))], ok: r.int("nozzle_target_temper") == celsius, exit: .wrongState)
    }
}

struct GCodeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "gcode", abstract: "Send G-code lines to an idle printer, such as G28 or G1 Y90.")
    @Argument(help: "G-code lines; each argument is one line.") var lines: [String]
    @Flag(name: .shortAndLong) var yes = false
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        try await withPrinter(try printer.config()) { p in
            let r = try await p.status()
            if r.busy { throw Stop("the printer is \(r.state ?? "busy"); G-code is for an idle printer", .wrongState) }
            try confirm("Send \(lines.joined(separator: "; "))?", yes)
            try await p.command("gcode_line", lines.joined(separator: "\n") + "\n")
        }
        if !out.json { say("Sent") }
        try Output.done(["sent": lines])
    }
}

struct Files: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List files on the printer's SD card.")
    @Argument var path = "/"
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        let listing = try listFiles(try printer.config(), path)
        if !out.json { print(listing, terminator: "") }
        try Output.done(["path": path, "files": parseListing(listing).map(JSON.object)])
    }
}
