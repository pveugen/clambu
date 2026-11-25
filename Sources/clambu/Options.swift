import ArgumentParser
import ClambuCore
import Foundation

struct JSONFlag: ParsableArguments {
    @Flag(help: "Print the result as JSON on stdout; progress goes to stderr.") var json = false
}

struct PrinterOption: ParsableArguments {
    @Option(name: .long, help: "Printer config name in ~/.config/bambu (default: the only one there, or CLAMBU_PRINTER).")
    var printer = PrinterConfig.defaultName()
    func config() throws -> PrinterConfig { try PrinterConfig.load(printer) }
}

struct SliceOptions: ParsableArguments {
    @Argument(help: "STL files.") var stl: [String]
    @Option(name: .shortAndLong, help: "A preset from clambu materials (default: the printer's MATERIAL).") var material: String?
    @Option(name: .shortAndLong, help: "The .gcode.3mf to write (default next to the first STL).") var output: String?
    @Option(name: .shortAndLong, help: "Layer height in mm, such as 0.12 or 0.20 (default: the printer's standard).") var layer: String?
    @Option(help: "Build plate, such as \"Textured PEI Plate\" or \"Cool Plate\" (default: the printer's PLATE).") var plate: String?
    @Option var walls = 3
    @Option(help: "Infill percent.") var infill = 15
    @Flag var supports = false
}

struct SendOptions: ParsableArguments {
    @Option(help: "AMS slot 1-4; leave out for the external spool.") var amsSlot: Int?
    @Option(help: "How the printer finds the file: sdcard or ftp.") var urlScheme = "sdcard"
    @Option(help: "Minutes to wait for layer 1.") var watchMinutes = 15
    @Flag(help: "Skip the layer 1 photo.") var noSnap = false
    @Flag(help: "Keep following the print after layer 1 even when the output isn't a terminal.") var follow = false
    @Flag(help: "Stop after layer 1 instead of following the print.") var noFollow = false
    @Flag(help: "Skip the camera check of the plate.") var plateIsClear = false
    @Flag(name: .shortAndLong, help: "Skip the final y/N (every check still runs). JSON mode needs it.") var yes = false
}

struct ServeOptions: ParsableArguments {
    @Option(help: "Port for the web page and API.") var port: UInt16 = 8765
    @Flag(help: "Serve on this Mac only, not on Tailscale.") var local = false
    @Flag(name: .shortAndLong, help: "No macOS notifications.") var quiet = false
}

func confirm(_ question: String, _ yes: Bool) throws {
    if yes { return }
    if Output.json { throw Stop("\(question) Pass --yes; JSON mode never asks.", .cancelled) }
    guard isatty(0) != 0 else { throw Stop("needs a yes; run it in a terminal or pass --yes", .cancelled) }
    print("   \(question) [y/N] ", terminator: "")
    fflush(stdout)
    guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "y" else { throw Stop("cancelled", .cancelled) }
}

func withPrinter<T>(_ cfg: PrinterConfig, _ f: (Printer) async throws -> T) async throws -> T {
    let p = Printer(cfg)
    try await p.connect()
    defer { p.close() }
    return try await f(p)
}
