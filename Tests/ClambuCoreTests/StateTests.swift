@testable import ClambuCore
import Foundation
import XCTest

final class StateTests: XCTestCase {
    let printing: [String: Any] = [
        "gcode_state": "RUNNING", "subtask_name": "phone_stand", "mc_percent": 62, "layer_num": 180, "total_layer_num": 290,
        "mc_remaining_time": 84, "nozzle_temper": 219.6, "nozzle_target_temper": 220, "bed_temper": 65.0,
        "bed_target_temper": 65, "spd_lvl": 3, "nozzle_diameter": "0.4", "vt_tray": ["tray_type": "PLA"],
    ]

    func testExitCodesAreFixed() {
        XCTAssertEqual(Exit.allCases.map(\.rawValue), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(Exit.allCases.map(\.name), ["ok", "refused", "usage", "unreachable", "wrong_state", "cancelled", "setup"])
        XCTAssertEqual(Stop("x").exit, .refused)
    }

    func testStateFromReport() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = PrinterState(Report(printing), at: now)
        XCTAssertEqual(s.label, "printing")
        XCTAssertTrue(s.busy)
        XCTAssertEqual(s.percent, 62)
        XCTAssertEqual(s.nozzle, 220)
        XCTAssertEqual(s.speed, "sport")
        XCTAssertEqual(s.spool, "PLA")
        XCTAssertEqual(s.remaining, "1h 24m")
        XCTAssertEqual(s.finishAt, now.addingTimeInterval(84 * 60))
        XCTAssertEqual(s.tone, .good)
    }

    func testIdleStateHasNoProgress() {
        let s = PrinterState(Report(["gcode_state": "IDLE", "mc_percent": 100, "layer_num": 3]))
        XCTAssertFalse(s.busy)
        XCTAssertNil(s.percent)
        XCTAssertNil(s.layer)
        XCTAssertEqual(s.label, "idle")
    }

    func testStateJSONIsSnakeCaseAndRoundTrips() throws {
        let s = PrinterState(Report(printing), at: Date(timeIntervalSince1970: 1_800_000_000))
        let text = JSON.string(s)
        XCTAssertTrue(text.contains("\"total_layers\" : 290"))
        XCTAssertTrue(text.contains("\"finish_at\" : \"2027-01-15"))
        let back = try JSON.decoder().decode(PrinterState.self, from: Data(text.utf8))
        XCTAssertEqual(back, s)
    }

    func testNotableEvents() {
        let s = PrinterState(Report(printing))
        XCTAssertFalse(Event(.status, "", state: s).notable)
        XCTAssertFalse(Event(.frame, "").notable)
        XCTAssertTrue(Event(.layer, "", state: s, layer: 1).notable)
        XCTAssertFalse(Event(.layer, "", state: s, layer: 7).notable)
        XCTAssertTrue(Event(.layer, "", state: s, layer: 180).notable)
        XCTAssertTrue(Event(.layer, "", state: s, layer: 290).notable)
        XCTAssertTrue(Event(.alert, "").notable)
    }

    func testHistoryKeepsTheLastSamples() {
        var h = History()
        var s = PrinterState(Report(printing))
        for i in 0..<(History.keep + 30) { s.nozzle = i; h.add(s) }
        XCTAssertEqual(h.nozzle.count, History.keep)
        XCTAssertEqual(h.nozzle.last, History.keep + 29)
    }

    func testListingParses() {
        let text = """
        drw-rw-rw-   1 root  root         0 Jul 11 22:37 model
        -rw-rw-rw-   1 root  root   2799455 Nov 24 19:56 phone_stand.gcode.3mf
        -rw-rw-rw-   1 root  root      1024 Nov 24 19:56 a name with spaces.3mf
        total 3
        """
        let f = parseListing(text)
        XCTAssertEqual(f.count, 3)
        XCTAssertEqual(f[0], FileEntry(name: "model", size: 0, directory: true, modified: "Jul 11 22:37"))
        XCTAssertEqual(f[1].size, 2_799_455)
        XCTAssertEqual(f[2].name, "a name with spaces.3mf")
    }
}

final class HUDTests: XCTestCase {
    func file(_ raw: [String: Any], connected: Bool = true, written: Date = Date()) -> HUD.File {
        HUD.File(pid: getpid(), written: written, connected: connected, state: PrinterState(Report(raw)), plate: nil,
                 url: nil, tailnetURL: nil, frameAt: nil)
    }

    let running: [String: Any] = ["gcode_state": "RUNNING", "subtask_name": "phone_stand", "mc_percent": 62, "layer_num": 180,
                                  "total_layer_num": 290, "mc_remaining_time": 84]

    func testPlainLine() {
        let line = HUD.line(file(running), style: .plain)!
        XCTAssertTrue(line.hasPrefix("● phone_stand  62% "))
        XCTAssertTrue(line.contains("L180/290"))
        XCTAssertTrue(line.contains("done "))
    }

    func testPausedAndLost() {
        var paused = running; paused["gcode_state"] = "PAUSE"
        XCTAssertTrue(HUD.line(file(paused), style: .plain)!.contains("paused"))
        XCTAssertTrue(HUD.line(file(running, connected: false), style: .plain)!.contains("lost the printer"))
    }

    func testTmuxPillEscapesHashes() {
        var r = running; r["subtask_name"] = "part#2"
        let line = HUD.line(file(r), style: .tmux(background: "#282e42"))!
        XCTAssertTrue(line.contains("part##2"))
        XCTAssertTrue(line.hasPrefix("#[fg=#282e42,bg=default]"))
        XCTAssertTrue(line.hasSuffix("#[default]"))
    }

    func testNothingWithoutAFile() {
        XCTAssertNil(HUD.line(nil, style: .plain))
    }

    func testThisMachine() {
        XCTAssertTrue(HUD.isThisMachine("localhost"))
        XCTAssertTrue(HUD.isThisMachine(ProcessInfo.processInfo.hostName.uppercased()))
        XCTAssertFalse(HUD.isThisMachine("no-such-mac-here"))
    }

    func testRemoteStateFollowsTheSameRule() {
        XCTAssertNotNil(HUD.worthShowing(file(running)))
        XCTAssertNil(HUD.worthShowing(file(["gcode_state": "IDLE"])))
        XCTAssertNotNil(HUD.worthShowing(file(["gcode_state": "FINISH", "subtask_name": "x"])))
    }

    func testTabProgress() {
        let s = PrinterState(Report(running))
        XCTAssertEqual(HUD.tabProgress(s, inTmux: false), "\u{1B}]9;4;1;62\u{07}")
        XCTAssertEqual(HUD.tabProgress(nil, inTmux: false), "\u{1B}]9;4;0\u{07}")
        XCTAssertEqual(HUD.tabProgress(s, inTmux: true), "\u{1B}Ptmux;\u{1B}\u{1B}]9;4;1;62\u{07}\u{1B}\\")
    }
}
