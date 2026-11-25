import ArgumentParser
import ClambuCore
import Foundation

@main
struct Clambu: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clambu",
        abstract: "Slice, print and watch a Bambu Lab 3D printer from the terminal, no Bambu Studio window.",
        discussion: """
            Every print is checked twice. Slicing fails unless the G-code uses the printer's own start routine, the layer 1 nozzle temperature is the material's and inside its safe range, and the bed temperature matches the plate. Sending refuses unless the file passes those checks again, it is sliced for this printer model, the printer is idle, its nozzle size matches, the loaded spool is the file's material, and the camera sees a clear plate.

            Every command takes --json: the result is one JSON document on stdout, progress goes to stderr. Exit codes: 0 ok, 1 a safety check refused, 2 usage, 3 the printer can't be reached, 4 the printer is in the wrong state, 5 cancelled or needs --yes, 6 setup missing.

            Start with: clambu setup. It needs LAN Only mode and Developer Mode on the printer, and saves the printer to ~/.config/bambu/<name>.env.
            """,
        version: "0.4.0",
        subcommands: [Setup.self, PrintCmd.self, Slice.self, Check.self, Send.self, Status.self, Watch.self, Events.self,
                      HUDCmd.self, PlateCmd.self, Cam.self, GCodeCmd.self, Pause.self, Resume.self, StopCmd.self,
                      Speed.self, Temp.self, Files.self, Materials.self, Doctor.self, RenderMock.self]
    )

    static func main() async {
        Output.json = CommandLine.arguments.contains("--json")
        do {
            var command = try parseAsRoot()
            if var c = command as? AsyncParsableCommand { try await c.run() } else { try command.run() }
        } catch let stop as Stop {
            fail(stop.exit, stop.message)
        } catch let code as ExitCode {
            Foundation.exit(code.rawValue)
        } catch {
            let code = exitCode(for: error)
            if code == .success { exit(withError: error) }
            if code == .validationFailure {
                let message = fullMessage(for: error)
                fail(.usage, message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message)
            }
            fail(.refused, "\(error)")
        }
    }
}

func fail(_ exit: Exit, _ message: String) -> Never {
    if Output.json {
        var d = Output.context
        d["error"] = ["code": exit.name, "exit": Int(exit.rawValue), "message": message]
        Output.result(d, ok: false)
    } else {
        FileHandle.standardError.write(Data("STOP: \(message)\n".utf8))
    }
    Foundation.exit(exit.rawValue)
}

extension Output {
    nonisolated(unsafe) static var context: [String: Any] = [:]

    static func done(_ fields: [String: Any] = [:], ok: Bool = true, exit: Exit = .refused) throws {
        if json {
            var d = context
            d.merge(fields) { _, new in new }
            result(d, ok: ok)
        }
        if !ok { throw ExitCode(exit.rawValue) }
    }
}
