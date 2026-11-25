import Foundation

public final class Monitor: @unchecked Sendable {
    public struct Options: Sendable {
        public var every = 30
        public var notify = true
        public var judgePlate = true
        public var keepFinished = true
        public var timelapseMinutes: Double = 0
        public var serve = true
        public var port: UInt16 = 8765
        public var tailscale = true
        public var writeState = true
        public var statusEvery: Double = 5
        public var sharpOf = 3
        public init() {}
    }

    public let cfg: PrinterConfig
    public let opts: Options
    let printer: Printer
    private let lock = NSLock()
    private var state = PrinterState.connecting
    private var history = History()
    private var frameData: Data?
    private var frameAt: Date?
    private var framePath: String?
    private var plate: PlateState?
    private var log: [Event] = []
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var servers: [APIServer] = []
    private var localURL: String?
    private var tailnetURL: String?
    private var grabNow = false
    private var stopped = false
    private var connected = false
    private var sawBusy = false
    private var finishingPrint = false
    private let tmp: String

    public init(_ cfg: PrinterConfig, _ opts: Options = Options()) {
        self.cfg = cfg
        self.opts = opts
        printer = Printer(cfg)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clambu-monitor-\(getpid())").path
    }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    public func start() async throws {
        try await printer.connect()
        locked { connected = true }
        let first = try await printer.status(wait: 6)
        if first.state != nil { apply(first) }
        if opts.serve { startServers() }
        tasks.append(Task.detached { [self] in await statusLoop() })
        if cameraEvery > 0 { tasks.append(Task.detached { [self] in await cameraLoop() }) }
    }

    public func stop() {
        let (subs, srv) = locked { () -> ([AsyncStream<Event>.Continuation], [APIServer]) in
            stopped = true
            let s = Array(subscribers.values)
            subscribers.removeAll()
            return (s, servers)
        }
        for t in tasks { t.cancel() }
        for s in srv { s.stop() }
        for c in subs { c.finish() }
        printer.close()
        if opts.writeState { HUD.clear() }
        try? FileManager.default.removeItem(atPath: tmp)
    }

    var cameraEvery: Int {
        if !cfg.machine.hasCamera { return 0 }
        if opts.every > 0 { return opts.every }
        return opts.timelapseMinutes > 0 ? Int(opts.timelapseMinutes * 60) : 0
    }

    public func snapshot() -> Snapshot {
        locked {
            Snapshot(state: state, history: history, frameAt: frameAt, framePath: framePath, plate: plate,
                     localURL: localURL, tailnetURL: tailnetURL, every: cameraEvery, log: log, connected: connected)
        }
    }

    public var latestFrame: Data? { locked { frameData } }

    public var finishing: Bool { locked { finishingPrint } }

    public func events() -> AsyncStream<Event> {
        let id = UUID()
        let (stream, c) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let done = locked { () -> Bool in
            if stopped { return true }
            subscribers[id] = c
            return false
        }
        if done { c.finish() }
        c.onTermination = { [weak self] _ in self?.locked { _ = self?.subscribers.removeValue(forKey: id) } }
        return stream
    }

    public func post(_ e: Event) {
        let subs = locked { () -> [AsyncStream<Event>.Continuation] in
            if e.kind != .status && e.kind != .frame {
                log.append(e)
                if log.count > 200 { log.removeFirst(log.count - 200) }
            }
            return Array(subscribers.values)
        }
        for c in subs { c.yield(e) }
    }

    public func message(_ text: String) { post(Event(.message, text)) }

    public func grabFrame() { locked { grabNow = true } }

    public func pause() async { await send("pause") { try await self.printer.command("pause") } }
    public func resume() async { await send("resume") { try await self.printer.command("resume") } }
    public func stopPrint() async { await send("stop") { try await self.printer.command("stop") } }
    public func speed(_ level: Int) async {
        guard let name = speeds.first(where: { $0.1 == level })?.0 else { return }
        await send("speed \(name)") { try await self.printer.command("print_speed", "\(level)") }
    }

    private func send(_ what: String, _ f: () async throws -> Void) async {
        do { try await f(); message("\(what) sent") } catch { post(Event(.error, "\(what) failed: \(error)")) }
    }

    func apply(_ r: Report) {
        let now = Date()
        let new = PrinterState(r, at: now)
        let (old, wasBusy) = locked { () -> (PrinterState, Bool) in
            let o = state
            state = new
            history.add(new)
            let w = sawBusy
            if new.busy { sawBusy = true }
            return (o, w)
        }
        post(Event(.status, new.label, at: now, state: new))
        if let s = new.state, let before = old.state, s != before {
            let what = new.job.isEmpty ? "the print" : new.job
            post(Event(.state, "\(what): \(new.label)", at: now, state: new, from: before, to: s))
            if opts.notify { notify("Printer", "\(what): \(new.label)") }
            if (s == "FINISH" || s == "FAILED") && (wasBusy || old.busy) {
                let line = s == "FINISH" ? "Finished. Let the bed cool before taking the parts off." : "The print failed. Check the printer."
                post(Event(.finished, line, at: now, state: new, from: before, to: s))
                if s == "FINISH" && opts.keepFinished {
                    locked { finishingPrint = true }
                    Task.detached { [self] in
                        await keepFinishedPlate()
                        locked { finishingPrint = false }
                    }
                }
            }
        }
        if let l = new.layer, l != old.layer, new.state == "RUNNING" {
            post(Event(.layer, "layer \(l) of \(new.totalLayers.map(String.init) ?? "?")", at: now, state: new, layer: l))
        }
        for a in Set(new.alerts).subtracting(old.alerts) {
            post(Event(.alert, "the printer says \(a)", at: now, state: new))
            if opts.notify { notify("Printer needs a look", a) }
        }
        if opts.writeState { HUD.write(snapshot()) }
    }

    func statusLoop() async {
        var misses = 0
        while !Task.isCancelled && !locked({ stopped }) {
            try? await Task.sleep(nanoseconds: UInt64(opts.statusEvery * 1_000_000_000))
            if Task.isCancelled { break }
            if let r = try? await printer.status(wait: 4), r.state != nil {
                misses = 0
                if !locked({ connected }) { locked { connected = true }; message("connected to the printer again") }
                apply(r)
            } else {
                misses += 1
                if misses == 3 {
                    locked { connected = false }
                    post(Event(.error, "no word from the printer; reconnecting"))
                    if opts.writeState { HUD.write(snapshot()) }
                }
                if misses >= 3 {
                    printer.close()
                    try? await printer.connect()
                }
            }
        }
    }

    func cameraLoop() async {
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        var nextTimelapse = Date()
        var failures = 0
        while !Task.isCancelled && !locked({ stopped }) {
            let started = Date()
            do {
                let printing = locked { state.busy }
                let data = try await sharpSnapshot(cfg, count: printing ? opts.sharpOf : 1).frame
                failures = 0
                let path = "\(tmp)/frame.jpg"
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                let now = Date()
                locked { frameData = data; frameAt = now; framePath = path }
                try? FileManager.default.createDirectory(atPath: Paths.snaps, withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: "\(Paths.snaps)/live.jpg"), options: .atomic)
                post(Event(.frame, "new camera frame", at: now, path: path))
                let current = locked { state }
                if opts.timelapseMinutes > 0, current.busy, now >= nextTimelapse {
                    let kept = "\(Paths.snaps)/\(timestamp())-\(current.job)-L\(current.layer ?? 0).jpg"
                    if (try? data.write(to: URL(fileURLWithPath: kept))) != nil { post(Event(.message, "kept a frame", path: kept)) }
                    nextTimelapse = now.addingTimeInterval(opts.timelapseMinutes * 60)
                }
                if opts.judgePlate && !current.busy && current.state != nil && Plate.count("empty") > 0 {
                    let v = try await Plate.judge(path)
                    let p = PlateState(v)
                    let changed = locked { () -> Bool in
                        let c = plate?.verdict != p.verdict
                        plate = p
                        return c
                    }
                    if changed { post(Event(.plate, "the plate looks \(p.verdict)", plate: p)) }
                } else if current.busy {
                    locked { plate = nil }
                }
            } catch {
                failures += 1
                if failures == 1 { post(Event(.error, "camera: \(error)")) }
            }
            while Date().timeIntervalSince(started) < Double(cameraEvery) {
                if locked({ grabNow || stopped }) || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            locked { grabNow = false }
        }
    }

    func keepFinishedPlate() async {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        guard let frame = try? await saveSnap(cfg, "finished", best: 5) else { return }
        post(Event(.message, "photo of the finished print", path: frame))
        if Plate.count("empty") > 0, let v = try? await Plate.judge(frame), v.verdict == "clear" { return }
        if let kept = try? await Plate.remember(frame, "busy") {
            post(Event(.message, "kept it as a busy plate reference", path: kept))
        }
    }

    func startServers() {
        let ts = opts.tailscale ? tailscaleSelf() : nil
        for port in opts.port..<(opts.port + 10) {
            // Address reuse lets a restarted watch bind while old connections close, but it would also bind next to another server, so ask the port first.
            if portOpen("127.0.0.1", port, timeout: 0.3) || ts.map({ portOpen($0.ip, port, timeout: 0.3) }) == true { continue }
            guard let local = try? APIServer(monitor: self, host: "127.0.0.1", port: port), let got = local.start() else { continue }
            servers.append(local)
            locked { localURL = "http://127.0.0.1:\(got)/" }
            if let ts, let s = try? APIServer(monitor: self, host: ts.ip, port: got), let p = s.start() {
                servers.append(s)
                locked { tailnetURL = "http://\(ts.name):\(p)/" }
            }
            return
        }
    }
}
