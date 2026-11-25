import ClambuCore
import Foundation
import SwiftTUICLI

public enum Render {
    public enum Scene: String, CaseIterable, Sendable { case printing, heating, paused, finished, idle, alert, lost }

    public static func snapshot(_ scene: Scene, now: Date) -> Snapshot {
        var raw: [String: Any] = [
            "gcode_state": "RUNNING", "subtask_name": "phone_stand", "mc_percent": 62, "layer_num": 180, "total_layer_num": 290,
            "mc_remaining_time": 84, "nozzle_temper": 219.6, "nozzle_target_temper": 220, "bed_temper": 65.0,
            "bed_target_temper": 65, "spd_lvl": 2, "nozzle_diameter": "0.4", "vt_tray": ["tray_type": "PLA"], "wifi_signal": "-51dBm",
        ]
        switch scene {
        case .printing, .lost: break
        case .heating:
            raw["gcode_state"] = "PREPARE"; raw["mc_percent"] = 0; raw["layer_num"] = 0; raw["nozzle_temper"] = 164.0; raw["bed_temper"] = 58.0
            raw["mc_remaining_time"] = 227
        case .paused: raw["gcode_state"] = "PAUSE"
        case .finished:
            raw["gcode_state"] = "FINISH"; raw["mc_percent"] = 100; raw["nozzle_temper"] = 61.0; raw["nozzle_target_temper"] = 0
            raw["bed_temper"] = 44.0; raw["bed_target_temper"] = 0
        case .idle:
            raw = ["gcode_state": "IDLE", "nozzle_temper": 27.0, "bed_temper": 24.0, "nozzle_diameter": "0.4", "vt_tray": ["tray_type": "PLA"]]
        case .alert: raw["hms"] = [["attr": 0x0300_0100, "code": 0x0001_0007]]
        }
        let state = PrinterState(Report(raw), at: now)
        var h = History()
        for i in 0..<History.keep {
            var s = state
            let t = Double(i) / Double(History.keep)
            s.nozzle = scene == .heating ? Int(25 + 140 * t) : (t < 0.2 ? Int(25 + 195 * t / 0.2) : 219 + (i % 7 == 0 ? 1 : 0) - (i % 11 == 0 ? 1 : 0))
            s.bed = scene == .heating ? Int(24 + 34 * t) : (t < 0.2 ? Int(24 + 41 * t / 0.2) : 65)
            if scene == .finished { s.nozzle = max(61, 220 - Int(160 * t)); s.bed = max(44, 65 - Int(21 * t)) }
            if scene == .idle { s.nozzle = 27; s.bed = 24 }
            h.add(s)
        }
        let plate = scene == .idle ? PlateState(Plate.Verdict(verdict: "clear", empty: 0.971, tile: 0.962, tiles: [], busy: nil, fingerprint: nil), at: now) : nil
        func at(_ m: Int) -> Date { now.addingTimeInterval(Double(-m) * 60) }
        let log = scene == .idle ? [] : [
            Event(.state, "phone_stand: printing", at: at(96), state: state),
            Event(.layer, "layer 1 of 290", at: at(96), state: state, layer: 1),
            Event(.message, "photo of layer 1", at: at(95)),
            Event(.layer, "layer 100 of 290", at: at(52), state: state, layer: 100),
            Event(.message, "speed sport sent", at: at(31)),
            Event(.layer, "layer 180 of 290", at: at(1), state: state, layer: 180),
        ]
        return Snapshot(state: state, history: h, frameAt: now.addingTimeInterval(-4), framePath: nil, plate: plate,
                        localURL: "http://127.0.0.1:8765/", tailnetURL: "http://my-mac:8765/", every: 10, log: log,
                        connected: scene != .lost)
    }

    @MainActor public static func panel(_ scene: Scene, width: Int, color: Bool = true, now: Date = Date()) -> String {
        let model = PanelModel(snapshot: snapshot(scene, now: now), now: now)
        return RenderOnce.render(PanelView(model: model, width: width), width: width, environment: env(color), isStdoutTTY: color)
    }

    @MainActor public static func follow(_ scene: Scene, width: Int, color: Bool = true, now: Date = Date()) -> String {
        let s = snapshot(scene, now: now).state
        func at(_ m: Int) -> Date { now.addingTimeInterval(Double(-m) * 60) }
        let events = [
            Event(.state, "following phone_stand, heating up", at: at(101), state: s),
            Event(.state, "phone_stand: printing", at: at(96), state: s),
            Event(.layer, "layer 1 of 290", at: at(96), state: s, layer: 1),
            Event(.message, "photo of layer 1", at: at(95), path: "\(Paths.snaps)/20261124-200712-phone_stand-layer1.jpg"),
            Event(.layer, "layer 100 of 290", at: at(52), state: s, layer: 100),
            Event(.message, "speed sport sent", at: at(31)),
            Event(.message, "speed standard sent", at: at(24)),
            Event(.layer, "layer 180 of 290", at: at(1), state: s, layer: 180),
        ]
        var out = events.map { color ? logLine($0) : "\(timeOfDay($0.at))  \($0.message)" }.joined(separator: "\n")
        out += "\n" + panel(scene, width: width - 1, color: color, now: now)
        return out
    }

    static func env(_ color: Bool) -> [String: String] {
        color ? ["LANG": "en_US.UTF-8", "COLORTERM": "truecolor", "TERM": "xterm-256color"]
              : ["LANG": "en_US.UTF-8", "NO_COLOR": "1", "TERM": "xterm-256color"]
    }
}
