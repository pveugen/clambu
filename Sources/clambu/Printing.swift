import ArgumentParser
import ClambuCore
import ClambuTerminal
import Foundation

struct PrintCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "print", abstract: "Slice, check, upload and start in one go.")
    @OptionGroup var slice: SliceOptions
    @OptionGroup var send: SendOptions
    @OptionGroup var printer: PrinterOption
    @OptionGroup var out: JSONFlag
    func run() async throws {
        let cfg = try printer.config()
        let file = try await slice.slice(for: cfg)
        try await sendFile(file, plate: 1, send, cfg)
    }
}

struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check file, printer and plate, upload, start, and follow the print.")
    @Argument var file: String
    @Option(help: "Plate number inside the .3mf.") var plate = 1
    @OptionGroup var send: SendOptions
    @OptionGroup var printer: PrinterOption
    @OptionGroup var out: JSONFlag
    func run() async throws { try await sendFile(file, plate: plate, send, try printer.config()) }
}

func sendFile(_ file: String, plate: Int, _ o: SendOptions, _ cfg: PrinterConfig) async throws {
    let path = URL(fileURLWithPath: file).standardizedFileURL.path
    if let slot = o.amsSlot, !(1...4).contains(slot) { throw Stop("--ams-slot must be 1-4", .usage) }
    if Output.json && o.follow { throw Stop("--follow doesn't mix with --json; follow with: clambu events --json", .usage) }
    Output.context["file"] = path

    say("1. File check")
    let (gcode, info) = try fileCheck(path, plate: plate)
    if info.printer != cfg.machine.printerModel {
        throw Stop("the file is sliced for the \(info.printer), but \(cfg.name) is a \(cfg.machine.printerModel)")
    }

    say("2. Printer check")
    let printer = Printer(cfg)
    try await printer.connect()
    defer { printer.close() }
    try await printerCheck(printer, info, slot: o.amsSlot)
    try await checkPlate(cfg, skip: o.plateIsClear)

    let name = uploadName(path)
    let job = name.replacingOccurrences(of: ".gcode.3mf", with: "")
    Output.context["job"] = job
    say("3. Ready: \(name), \(info.time), \(info.grams)g of \(info.filament)")
    say("   Is the plate clear and the nozzle clean?")
    try confirm("Start this print?", o.yes)

    try upload(cfg, path, as: name)
    try await start(printer, name: name, job: job, plate: plate, gcode: gcode, o)
    Output.context["started"] = true
    say("4. Started; following the heat-up until layer 1")
    guard try await watchToLayer1(printer, info, minutes: o.watchMinutes) else {
        try Output.done()
        return
    }
    if !o.noSnap && cfg.machine.hasCamera { try await layerOnePhoto(cfg, job: job) }
    say("   Look at the first layer now. Stop with: clambu stop")
    printer.close()
    try Output.done()

    if !Output.json && !o.noFollow && (o.follow || isatty(1) != 0) {
        var opts = Monitor.Options()
        opts.every = 30
        try await followPrint(cfg, opts)
    }
}

func fileCheck(_ path: String, plate: Int) throws -> (String, CheckInfo) {
    let c = try checkFile(path, plate: plate)
    printCheck(c.info, c.problems, warnings: c.warnings)
    Output.context["check"] = ["info": JSON.object(c.info), "problems": c.problems, "warnings": c.warnings]
    if !c.problems.isEmpty { throw Stop("the file failed its self-check; fix it and slice it again") }
    return (c.gcode, c.info)
}

func printerCheck(_ printer: Printer, _ info: CheckInfo, slot: Int?) async throws {
    let r = try await printer.status()
    guard let state = r.state else { throw Stop("no status from the printer", .unreachable) }
    Output.context["printer"] = JSON.object(PrinterState(r))
    if r.busy { throw Stop("printer is busy (\(state))", .wrongState) }
    let nozzle = r.str("nozzle_diameter") ?? ""
    if let a = Double(nozzle), let b = Double(info.nozzleDiameter), a != b {
        throw Stop("printer has a \(nozzle)mm nozzle, the file is sliced for \(info.nozzleDiameter)mm")
    }
    let label = slot.map { "AMS slot \($0)" } ?? "external spool"
    let loaded = r.spool(slot: slot).uppercased()
    if loaded.isEmpty { throw Stop("the printer has no material set for the \(label). Set it on the printer screen first.") }
    if loaded != info.filament.uppercased() { throw Stop("the \(label) is \(loaded), but the file is sliced for \(info.filament)") }
    for h in r.hms { say("  health message on the printer: \(h)") }
    say("  idle (\(state)), \(nozzle.isEmpty ? "?" : nozzle)mm nozzle, \(label) \(loaded): matches")
}

func checkPlate(_ cfg: PrinterConfig, skip: Bool) async throws {
    if !cfg.machine.hasCamera {
        say("  plate: camera check skipped, clambu can't read the \(cfg.machine.model)'s camera yet. Check the plate yourself.")
        Output.context["plate"] = ["verdict": "unsupported"]
        return
    }
    if skip {
        say("  plate: you said it's clear, camera check skipped")
        Output.context["plate"] = ["verdict": "skipped"]
        return
    }
    if Plate.count("empty") == 0 {
        say("  plate: camera check skipped, no reference yet (clear the plate and run: clambu plate learn)")
        Output.context["plate"] = ["verdict": "unknown"]
        return
    }
    let frame = try await saveSnap(cfg, "plate-check")
    let v = try await Plate.judge(frame)
    Output.context["plate"] = JSON.object(PlateState(v))
    if v.verdict == "clear" {
        say("  plate: clear, \(v.why)")
        try? FileManager.default.removeItem(atPath: frame)
    } else {
        throw Stop("the plate doesn't look clear (\(v.verdict): \(v.why)). Frame: \(frame)\n"
                   + "      Clear it, or pass --plate-is-clear if the camera is wrong (then run clambu plate learn so it knows better).")
    }
}

func uploadName(_ path: String) -> String {
    var base = (path as NSString).lastPathComponent
    if base.hasSuffix(".3mf") { base.removeLast(4) }
    return (base.hasSuffix(".gcode") ? base : base + ".gcode") + ".3mf"
}

func start(_ printer: Printer, name: String, job: String, plate: Int, gcode: String, _ o: SendOptions) async throws {
    try await printer.publish(["print": [
        "sequence_id": "0", "command": "project_file", "param": "Metadata/plate_\(plate).gcode",
        "project_id": "0", "profile_id": "0", "task_id": "0", "subtask_id": "0",
        "subtask_name": job, "file": name,
        "url": o.urlScheme == "ftp" ? "ftp://\(name)" : "file:///sdcard/\(name)",
        "md5": md5(Data(gcode.utf8)),
        "timelapse": false, "bed_type": "auto", "bed_leveling": true,
        "flow_cali": false, "vibration_cali": true, "layer_inspect": false,
        "use_ams": o.amsSlot != nil, "ams_mapping": o.amsSlot.map { [$0 - 1] } ?? [],
    ] as [String: Any]])
}

func watchToLayer1(_ printer: Printer, _ info: CheckInfo, minutes: Int) async throws -> Bool {
    let started = Date()
    var last: String?, running = false
    while Date().timeIntervalSince(started) < Double(minutes * 60) {
        let r = try await printer.status(wait: 3)
        let s = r.state
        if let s, s != last { say("   state: \(s)"); last = s }
        if let e = r.error { say("   printer reported error \(e)"); return false }
        if (s == "FAILED" || s == "FINISH") && running { say("   the print ended early; check the printer"); return false }
        if s == "PREPARE" || s == "RUNNING" { running = true }
        if !running && Date().timeIntervalSince(started) > 60 {
            say("   the printer did not start within 60s; if it can't find the file, retry with --url-scheme ftp")
            return false
        }
        if s == "RUNNING", (r.int("layer_num") ?? 0) >= 1 {
            let nozzle = r.int("nozzle_target_temper") ?? 0, bed = r.int("bed_target_temper") ?? 0
            let planned = nozzle == info.nozzleFirstLayer && bed == info.bedFirstLayer
            Output.context["layer1"] = ["nozzle_target": nozzle, "bed_target": bed, "as_planned": planned]
            say("   layer 1 is printing: nozzle target \(nozzle) C, bed target \(bed) C "
                + (planned ? "(as planned)" : "(NOT as planned, expected \(info.nozzleFirstLayer ?? 0) / \(info.bedFirstLayer ?? 0) C)"))
            return true
        }
        try await Task.sleep(nanoseconds: 4_000_000_000)
    }
    say("   still not on layer 1 after \(minutes)m; check the printer")
    return false
}

func layerOnePhoto(_ cfg: PrinterConfig, job: String) async throws {
    try await Task.sleep(nanoseconds: 20_000_000_000)
    do {
        let photo = try await saveSnap(cfg, job + "-layer1", best: 5)
        Output.context["layer1_photo"] = photo
        say("   Layer 1 photo: \(photo)")
        if !Output.json { await InlineImage.show(path: photo) }
    } catch {
        say("   no layer 1 photo (\(error))")
    }
}
