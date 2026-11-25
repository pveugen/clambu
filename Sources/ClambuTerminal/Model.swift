import ClambuCore
import Foundation
import Observation
import SwiftTUICLI

@MainActor @Observable
public final class PanelModel {
    @ObservationIgnored let monitor: Monitor?
    var snap: Snapshot
    var ask: Ask?
    var message = ""
    var messageAt = Date.distantPast
    var now = Date()
    var quit = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    enum Ask: Equatable {
        case pause, stop
        var question: String {
            switch self {
            case .pause: "Pause the print?"
            case .stop: "Stop the print? It can't be resumed."
            }
        }
    }

    init(monitor: Monitor) {
        self.monitor = monitor
        snap = monitor.snapshot()
    }

    init(snapshot: Snapshot, now: Date) {
        monitor = nil
        snap = snapshot
        self.now = now
    }

    func start() {
        guard let monitor, tasks.isEmpty else { return }
        let events = monitor.events()
        tasks.append(Task { @MainActor [weak self] in
            for await e in events {
                guard let self else { return }
                self.snap = monitor.snapshot()
                if e.kind == .message || e.kind == .error { self.say(e.message) }
            }
        })
        tasks.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.now = Date()
            }
        })
    }

    func stop() { for t in tasks { t.cancel() }; tasks.removeAll() }

    func say(_ s: String) { message = s; messageAt = Date() }

    var status: String { now.timeIntervalSince(messageAt) < 8 ? message : "" }

    @discardableResult
    func key(_ c: Character) -> Bool {
        let s = snap.state
        if let a = ask {
            ask = nil
            if c == "y" || c == "Y" {
                act { m in a == .pause ? await m.pause() : await m.stopPrint() }
            } else {
                say("cancelled")
            }
            return true
        }
        switch c {
        case "q": quit = true
        case "c": say("grabbing a frame"); monitor?.grabFrame()
        case "o":
            let target = snap.localURL ?? "\(Paths.snaps)/live.jpg"
            _ = try? ClambuCore.run("/usr/bin/open", [target], timeout: 10)
            say("opened \(target)")
        case "p":
            guard s.state == "RUNNING" || s.state == "PREPARE" else { say("nothing to pause"); return true }
            ask = .pause
        case "r":
            guard s.state == "PAUSE" else { say("nothing to resume"); return true }
            act { await $0.resume() }
        case "x":
            guard s.busy else { say("nothing to stop"); return true }
            ask = .stop
        case "1", "2", "3", "4":
            guard s.busy, let level = Int(String(c)) else { say("speed is for a running print"); return true }
            act { await $0.speed(level) }
        default:
            return false
        }
        return true
    }

    private func act(_ f: @escaping @Sendable (Monitor) async -> Void) {
        guard let m = monitor else { return }
        Task.detached { await f(m) }
    }
}
