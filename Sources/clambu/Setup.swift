import ArgumentParser
import ClambuCore
import Foundation

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect clambu to your printer and pick its model, nozzle, material and plate.",
        discussion: """
            Before you start, on the printer's screen:
              1. Turn on LAN Only mode. A1 and A1 mini: Settings > LAN Only Mode. P1P and P1S: Settings > WLAN > LAN Only Mode. X1, P2S and H2: Settings > LAN Only.
              2. On the same page, turn on Developer Mode and confirm.
              3. Note the IP address and the access code shown on that page, and the serial number under Settings > Device.

            clambu setup asks for anything you don't pass. In JSON mode, pass every option and the access code in PRINTER_ACCESS_CODE.
            """
    )
    @Option(help: "Name for this printer; the config goes to ~/.config/bambu/<name>.env (default: from the model).") var name: String?
    @Option(help: "The printer's IP address.") var ip: String?
    @Option(help: "The printer's serial number.") var serial: String?
    @Option(help: "Model, such as \"A1 mini\", P1S or \"X1 Carbon\" (default: from the serial number).") var model: String?
    @Option(help: "Nozzle size in mm (default: what the printer reports, else 0.4).") var nozzle: String?
    @Option(help: "Default material from clambu materials (default: matches the loaded spool).") var material: String?
    @Option(help: "Build plate (default: Textured PEI Plate).") var plate: String?
    @Flag(name: .shortAndLong, help: "Replace an existing config without asking.") var yes = false
    @OptionGroup var out: JSONFlag

    func run() async throws {
        let guided = !Output.json && isatty(0) != 0 && isatty(1) != 0 && (ip == nil || serial == nil)
        if guided {
            Onboarding.welcome()
            try Onboarding.printerSteps()
            Onboarding.step(2, "Tell clambu about your printer")
        } else {
            say("Set up clambu for your Bambu Lab printer.")
            say("On the printer's screen, turn on LAN Only mode and Developer Mode first (see clambu setup --help).\n")
        }

        let ip = try self.ip ?? ask("IP address")
        let serial = try (self.serial ?? ask("Serial number")).uppercased()
        let code = try ProcessInfo.processInfo.environment["PRINTER_ACCESS_CODE"].flatMap { $0.isEmpty ? nil : $0 } ?? askSecret("Access code")

        let known = Machine.models()
        let guess = Machine.guess(serial: serial)
        let pickedModel = try model ?? ask("Model (\(known.joined(separator: ", ")))", guess)
        guard let model = known.first(where: { $0.caseInsensitiveCompare(pickedModel) == .orderedSame }) else {
            throw Stop("unknown model '\(pickedModel)'. Choose from: \(known.joined(separator: ", "))", .usage)
        }

        if let guess, guess != model { say("  note: the serial number looks like an \(guess), not a \(model)") }
        if guided { Onboarding.step(3, "Connect and pick your defaults") } else { say("") }
        say("  Connecting to the \(model) at \(ip)...")
        var reported: Report?
        do {
            let probe = PrinterConfig(name: "setup", path: "", ip: ip, serial: serial, accessCode: code, machine: Machine(model: model))
            reported = try await withPrinter(probe) { try await $0.status() }
            say("  connected, the printer is \(reported?.state ?? "?")")
        } catch {
            say("  could not connect: \(error)")
            say("  Check that LAN Only mode and Developer Mode are on, that this Mac is on the same network, and the access code.")
            say("  The config is saved anyway; run clambu doctor when the printer is reachable.")
        }

        let nozzle = try self.nozzle ?? reported?.str("nozzle_diameter").flatMap { Double($0).map { String($0) } } ?? ask("Nozzle size in mm", "0.4")
        let machine = Machine(model: model, nozzle: nozzle)

        let spool = reported?.spool(slot: nil).uppercased() ?? ""
        let names = try materials().map(\.name)
        let suggested = names.first { $0.uppercased() == spool } ?? "pla"
        let material = try self.material ?? ask("Default material (\(names.joined(separator: ", ")))", suggested)
        guard names.contains(material) else { throw Stop("unknown material '\(material)'. Choose from: \(names.joined(separator: ", "))", .usage) }
        if (try? resolveProfile("filament", try ClambuCore.material(material).profile, for: machine)) == nil {
            say("  note: Bambu Studio has no \(material) profile for the \(machine.profile); slicing with it will fail")
        }

        let plates = plateKeys.keys.sorted()
        let plate = try self.plate ?? ask("Build plate (\(plates.joined(separator: ", ")))", defaultPlate)
        guard plates.contains(plate) else { throw Stop("unknown plate '\(plate)'. Choose from: \(plates.joined(separator: ", "))", .usage) }

        let name = self.name ?? model.lowercased().replacingOccurrences(of: " ", with: "")
        if FileManager.default.fileExists(atPath: PrinterConfig.path(name)) {
            try confirm("Replace \(PrinterConfig.path(name))?", yes)
        }
        let path = try PrinterConfig.write(name: name, ip: ip, serial: serial, accessCode: code, machine: machine, material: material, plate: plate)

        if guided { Onboarding.done(model: model, connected: reported != nil) }
        say("  Saved \(path) (only you can read it).")
        if PrinterConfig.names().count > 1 && PrinterConfig.defaultName() != name {
            say("  You have more than one printer: pass --printer \(name) or set CLAMBU_PRINTER=\(name).")
        }
        say("\n  Next:")
        say("    clambu doctor                  check everything")
        if machine.hasCamera { say("    clambu plate learn --sweep     with the plate clear, teach the camera what empty looks like") }
        say("    clambu print part.stl          slice, check, start and follow a print\n")
        try Output.done(["file": path, "name": name, "model": model, "nozzle": nozzle, "material": material, "plate": plate,
                         "connected": reported != nil, "state": reported?.state ?? NSNull()],
                        ok: reported != nil, exit: .unreachable)
    }
}

func ask(_ question: String, _ fallback: String? = nil) throws -> String {
    guard !Output.json, isatty(0) != 0 else {
        if let fallback { return fallback }
        throw Stop("\(question) is missing; pass it as an option", .usage)
    }
    while true {
        print("  \(question)\(fallback.map { " [\($0)]" } ?? ""): ", terminator: "")
        fflush(stdout)
        guard let line = readLine() else { throw Stop("cancelled", .cancelled) }
        let answer = line.trimmingCharacters(in: .whitespaces)
        if !answer.isEmpty { return answer }
        if let fallback { return fallback }
    }
}

func askSecret(_ question: String) throws -> String {
    guard !Output.json, isatty(0) != 0 else { throw Stop("set PRINTER_ACCESS_CODE; JSON mode never asks", .usage) }
    var buffer = [CChar](repeating: 0, count: 128)
    guard let raw = readpassphrase("  \(question) (hidden): ", &buffer, buffer.count, 0) else { throw Stop("cancelled", .cancelled) }
    let answer = String(cString: raw).trimmingCharacters(in: .whitespaces)
    return answer.isEmpty ? try askSecret(question) : answer
}

enum Onboarding {
    static let color = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    static func paint(_ text: String, _ c: UInt32, bold: Bool = false) -> String { color ? Palette.ansi(text, c, bold: bold) : text }
    static func line(_ width: Int) -> String { String(repeating: "─", count: width) }

    static func welcome() {
        let width = 26
        let art: [(String, UInt32)] = [
            ("  ═══════════╤══════════", Palette.dim),
            ("           ┌─┴─┐", Palette.sand),
            ("           └─┬─┘", Palette.sand),
            ("             ▼", Palette.sand),
            ("          ▗▄███▄▖", Palette.green),
            ("  ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔", Palette.dim),
        ]
        print("")
        print("    " + paint("┌" + line(width) + "┐", Palette.faint))
        for (text, c) in art {
            print("    " + paint("│", Palette.faint) + paint(text.padding(toLength: width, withPad: " ", startingAt: 0), c) + paint("│", Palette.faint))
        }
        print("    " + paint("└" + line(width) + "┘", Palette.faint))
        print("")
        print("    " + paint("c l a m b u", Palette.text, bold: true) + paint("   print from your terminal", Palette.dim))
        print("")
        print("    Three steps: switch on two settings on the printer, tell clambu")
        print("    where it is, and pick your defaults. It takes about two minutes.")
    }

    static func step(_ n: Int, _ title: String) {
        print("")
        print("  " + paint("\(n)/3", Palette.sand, bold: true) + "  " + paint(title, Palette.text, bold: true))
        print("  " + paint(line(title.count + 5), Palette.faint))
    }

    static func screen(_ rows: [(String, String, UInt32)]) {
        let width = 38
        let title = " printer screen "
        print("    " + paint("┌─" + title + line(width - title.count - 1) + "┐", Palette.faint))
        for (label, value, c) in rows {
            let gap = max(1, width - 4 - label.count - value.count)
            print("    " + paint("│", Palette.faint) + "  " + label + String(repeating: " ", count: gap) + paint(value, c, bold: true) + "  " + paint("│", Palette.faint))
        }
        print("    " + paint("└" + line(width) + "┘", Palette.faint))
    }

    static func printerSteps() throws {
        step(1, "On the printer")
        print("  clambu talks to the printer on your network. Bambu printers only take")
        print("  commands from other apps in LAN Only mode with Developer Mode on.")
        print("")
        screen([
            ("LAN Only Mode", "● ON", Palette.green),
            ("Developer Mode", "● ON", Palette.green),
            ("IP", "192.168.1.50", Palette.blue),
            ("Access code", "12345678", Palette.blue),
        ])
        print("")
        let paths = [
            ("A1, A1 mini", "Settings > LAN Only Mode (page 3)"),
            ("P1P, P1S", "Settings > WLAN > LAN Only Mode"),
            ("X1, P2S, H2", "Settings > LAN Only"),
        ]
        for (family, path) in paths {
            print("    " + paint(family.padding(toLength: 13, withPad: " ", startingAt: 0), Palette.sand) + path)
        }
        print("")
        print("  Turn on LAN Only Mode, then Developer Mode on the same page, and confirm.")
        print("  Keep that page open: it shows the IP address and the access code.")
        print("  The serial number is under Settings > Device.")
        print("")
        print("  " + paint("LAN Only mode disconnects Bambu's cloud, so Bambu Handy stops working until you turn it off.", Palette.dim))
        print("")
        print("  Press Enter when both are on. ", terminator: "")
        fflush(stdout)
        guard readLine() != nil else { throw Stop("cancelled", .cancelled) }
    }

    static func done(model: String, connected: Bool) {
        print("")
        if connected {
            print("    " + paint("╭──────────────╮", Palette.green))
            print("    " + paint("│   ✓  ready   │", Palette.green, bold: true) + "   " + paint("Your \(model) is set up.", Palette.text, bold: true))
            print("    " + paint("╰──────────────╯", Palette.green))
        } else {
            print("    " + paint("╭──────────────╮", Palette.amber))
            print("    " + paint("│   !  saved   │", Palette.amber, bold: true) + "   " + paint("Saved, but the \(model) didn't answer yet.", Palette.text, bold: true))
            print("    " + paint("╰──────────────╯", Palette.amber))
        }
        print("")
    }
}
