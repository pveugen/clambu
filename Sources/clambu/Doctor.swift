import ArgumentParser
import ClambuCore
import Foundation

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check Bambu Studio, the profiles, the printer config and the connection to the printer.")
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        var ok = true
        var checks: [[String: Any]] = []
        func line(_ good: Bool, _ msg: String) {
            ok = ok && good
            checks.append(["ok": good, "check": msg])
            say("  \(good ? "ok  " : "FAIL")  \(msg)")
        }
        line(FileManager.default.fileExists(atPath: Paths.studio), "Bambu Studio at \(Paths.studio)")
        let empties = Plate.count("empty"), busies = Plate.count("busy")
        say("        plate references: \(empties) empty, \(busies) busy" + (empties == 0 ? " (run clambu plate learn)" : ""))
        Output.context["plate_references"] = ["empty": empties, "busy": busies]
        let cfg: PrinterConfig
        do { cfg = try printer.config() } catch {
            line(false, "\(error)")
            try Output.done(["checks": checks], ok: false, exit: .setup)
            return
        }
        line(PrinterConfig.isPrivate(cfg.path), "\(cfg.path) is private (chmod 600)")
        say("        \(cfg.machine.printerModel) with a \(cfg.machine.nozzle)mm nozzle at \(cfg.ip), serial ...\(cfg.serial.suffix(4))")
        Output.context["printer"] = ["ip": cfg.ip, "serial_end": String(cfg.serial.suffix(4)), "model": cfg.machine.model, "nozzle": cfg.machine.nozzle]
        do { _ = try loadProfile("machine", cfg.machine.profile); line(true, "Bambu Studio profile \(cfg.machine.profile)") }
        catch { line(false, "\(error)") }
        let mat = cfg.material ?? "pla"
        do { line(true, "material \(mat): \(try resolveProfile("filament", try material(mat).profile, for: cfg.machine))") }
        catch { line(false, "material \(mat): \(error)") }
        if !cfg.machine.hasCamera { say("        camera: clambu can't read the \(cfg.machine.model)'s camera yet; the plate check and photos are off") }
        var reachable = true
        var ports: [(UInt16, String)] = [(8883, "status and commands"), (990, "file upload")]
        if cfg.machine.hasCamera { ports.append((6000, "camera")) }
        for (port, what) in ports {
            let open = portOpen(cfg.ip, port)
            reachable = reachable && open
            line(open, "port \(port) (\(what))")
        }
        do {
            let r = try await withPrinter(cfg) { try await $0.status() }
            line(r.state != nil, "MQTT login, printer is \(r.state ?? "?")")
            if let n = r.str("nozzle_diameter"), let a = Double(n), let b = Double(cfg.machine.nozzle), a != b {
                line(false, "the printer reports a \(n)mm nozzle; set PRINTER_NOZZLE=\(n) in \(cfg.path)")
            }
            if r.state != nil { Output.context["state"] = r.state }
        } catch {
            line(false, "\(error)")
            say("        Is LAN Only mode and Developer Mode on? See: clambu setup --help")
            reachable = false
        }
        say(ok ? "All good." : "Something needs fixing.")
        try Output.done(["checks": checks], ok: ok, exit: reachable ? .setup : .unreachable)
    }
}
