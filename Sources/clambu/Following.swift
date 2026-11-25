import ArgumentParser
import ClambuCore
import ClambuTerminal
import Foundation

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Printer state, progress, temperatures, spools, health.")
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        let r = try await withPrinter(try printer.config()) { try await $0.status() }
        guard r.state != nil else { throw Stop("No status received. Is Developer Mode on?", .unreachable) }
        if !out.json { say(r.describe) }
        try Output.done(["status": JSON.object(PrinterState(r)), "report": r.raw])
    }
}

func followPrint(_ cfg: PrinterConfig, _ opts: Monitor.Options, quitWhenIdle: Bool = false) async throws {
    let m = Monitor(cfg, opts)
    try await m.start()
    defer { m.stop() }
    let s = m.snapshot().state
    if quitWhenIdle && !s.busy {
        if Output.json {
            print(JSON.string(Event(.status, s.label, state: s), pretty: false))
        } else {
            say(s.oneline); say("Nothing is printing.")
        }
        return
    }
    if Output.json { await streamEvents(m, untilDone: true); return }
    try await Follow.run(m, untilDone: true)
}

func streamEvents(_ m: Monitor, untilDone: Bool) async {
    let first = m.snapshot().state
    print(JSON.string(Event(.status, first.label, state: first), pretty: false)); fflush(stdout)
    var wasBusy = first.busy
    for await e in m.events() {
        print(JSON.string(e, pretty: false)); fflush(stdout)
        if let s = e.state, e.kind == .status {
            if s.busy { wasBusy = true } else if untilDone && wasBusy { break }
        }
    }
}

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Follow the print until it ends: a log, a panel under it, notifications, and an optional timelapse.",
        discussion: "Keys: p pause, r resume, 1-4 speed, c frame, o open the web page, x stop, q quit. In a pipe or with --json it prints plain lines or JSON events instead.")
    @Option(help: "Seconds between status updates.") var every: Double = 5
    @Option(help: "Seconds between camera frames for the web page; 0 for none.") var frames = 30
    @Option(help: "Save a camera frame every this many minutes to ~/Pictures/clambu.") var snapEvery: Double = 0
    @OptionGroup var serve: ServeOptions
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        var opts = Monitor.Options()
        opts.statusEvery = every; opts.every = frames; opts.timelapseMinutes = snapEvery
        opts.port = serve.port; opts.tailscale = !serve.local; opts.notify = !serve.quiet
        try await followPrint(try printer.config(), opts, quitWhenIdle: true)
    }
}

struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream the printer's events as JSON lines, for scripts and agents.",
        discussion: "One JSON object per line: status, state, layer, frame, plate, alert, finished, message and error. Runs until you stop it, or until the print ends with --until-done.")
    @Flag(help: "Stop when the print ends.") var untilDone = false
    @Option(help: "Seconds between camera frames; 0 for none.") var frames = 0
    @Flag(help: "Also serve the web page and API.") var serve = false
    @Option(help: "Port for the web page and API.") var port: UInt16 = 8765
    @Flag(help: .hidden) var json = false
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        var opts = Monitor.Options()
        opts.every = frames; opts.serve = serve; opts.port = port; opts.notify = false; opts.judgePlate = frames > 0
        let m = Monitor(try printer.config(), opts)
        try await m.start()
        defer { m.stop() }
        await streamEvents(m, untilDone: untilDone)
    }
}

struct HUDCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hud",
        abstract: "The print in one line, for the tmux status bar or the Claude Code status line.",
        discussion: """
            Reads what a running clambu (watch, send, print) last saw, so it's instant and never talks to the printer. Prints nothing when nothing is printing.

            tmux:        set -g status-right "#(clambu hud --tmux --follow --from my-mac) ..."
            Claude Code: "statusLine": {"type": "command", "command": "clambu hud --from my-mac"}

            With --from, every machine shows the print of the Mac that prints. On that Mac, --from names itself and clambu hud reads its own file.
            """)
    @Flag(help: "tmux format codes, as a rounded pill.") var tmux = false
    @Option(help: "The pill's background for --tmux.") var pill = "#282e42"
    @Flag(help: "No color.") var plain = false
    @Option(help: "Fit in about this many columns.") var width = 64
    @Flag(help: "When nothing follows the printer, start a quiet watch in the background to follow it (at most every 2 minutes).") var follow = false
    @Option(help: "The Mac that prints. On any other machine, clambu hud reads the print from that Mac over Tailscale and never starts a watch.")
    var from: String? = ProcessInfo.processInfo.environment["CLAMBU_HUD_FROM"]
    @OptionGroup var out: JSONFlag
    @OptionGroup var printer: PrinterOption
    func run() async throws {
        var f = HUD.current()
        if f == nil, let host = from, !HUD.isThisMachine(host) {
            f = HUD.remote(host)
        } else if follow && f == nil {
            HUD.startFollower(printer: printer.printer)
        }
        if out.json {
            if let f { print(JSON.string(f, pretty: false)) } else { print("{}") }
            return
        }
        let style: HUD.Style = tmux ? .tmux(background: pill) : (plain ? .plain : .ansi)
        if let line = HUD.line(f, style: style, width: width) { print(line) }
    }
}
