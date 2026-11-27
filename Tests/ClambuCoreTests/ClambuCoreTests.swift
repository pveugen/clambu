@testable import ClambuCore
import Foundation
import XCTest

final class CheckTests: XCTestCase {
    func gcode(nozzle: Int, mark: Bool = true) -> String {
        """
        ; printer_model = Bambu Lab P1S
        ; machine_start_gcode = ;===== machine: P1S-0.4 ========================\\n;===== date: 20251031 =====\\nG28
        ; filament_type = PLA
        ; filament_settings_id = "PolyTerra PLA @BBL A1M"
        ; nozzle_temperature_initial_layer = 220
        ; nozzle_temperature_range_low = 190
        ; nozzle_temperature_range_high = 240
        ; curr_bed_type = Textured PEI Plate
        ; textured_plate_temp_initial_layer = 65
        ; nozzle_diameter = 0.4
        \(mark ? ";===== machine: P1S-0.4 ========================" : "G28")
        M140 S65
        M104 S\(nozzle)
        ; CHANGE_LAYER
        G1 X0
        """
    }

    func testGoodFilePasses() {
        let (info, problems) = checkGCode(gcode(nozzle: 220))
        XCTAssertEqual(problems, [])
        XCTAssertEqual(info.nozzleFirstLayer, 220)
        XCTAssertEqual(info.bedFirstLayer, 65)
    }

    func testWrongNozzleFails() {
        XCTAssertTrue(checkGCode(gcode(nozzle: 205)).1.contains { $0.contains("wants 220") })
    }

    func testGenericStartFails() {
        XCTAssertTrue(checkGCode(gcode(nozzle: 220, mark: false)).1.contains { $0.contains("start G-code") })
    }

    func testMarkOnlyInSettingsFails() {
        let text = gcode(nozzle: 220, mark: false)
        XCTAssertTrue(text.contains(";===== machine: P1S-0.4"))
        XCTAssertTrue(checkGCode(text).1.contains { $0.contains("not the Bambu Lab P1S's own") })
    }

    func testPrinterModelRead() {
        XCTAssertEqual(checkGCode(gcode(nozzle: 220)).0.printer, "Bambu Lab P1S")
    }

    func testRealPlate() throws {
        let path = ProcessInfo.processInfo.environment["CLAMBU_TEST_3MF"] ?? ""
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "set CLAMBU_TEST_3MF to a sliced PLA .gcode.3mf")
        let (info, problems) = checkGCode(try readPlateGCode(path))
        XCTAssertEqual(problems, [])
        XCTAssertEqual(info.filament, "PLA")
    }
}

final class BaseTests: XCTestCase {
    func layers(_ lengths: [Double], label: Int? = nil, height: Double = 0.08) -> String {
        var out = ["; nozzle_diameter = 0.4"]
        for (i, length) in lengths.enumerated() {
            out += ["; CHANGE_LAYER", "; Z_HEIGHT: \(0.2 + Double(i) * height)", "; LAYER_HEIGHT: \(i == 0 ? 0.2 : height)"]
            if let label { out.append("; start printing object, unique label id: \(label)") }
            out += ["G0 X0 Y0", "G1 X\(length) Y0 E1", "G1 X\(length) Y0 E-0.8"]
            if label != nil { out.append("; stop printing object, unique label id: \(label!)") }
        }
        return out.joined(separator: "\n")
    }

    func testFloatingBaseFails() {
        let problems = floatingBases(layers([10, 10, 10, 10, 10, 10, 3000, 3000]))
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("the model prints its base in the air"))
        XCTAssertTrue(problems[0].contains("4.0mm² on the plate"))
    }

    func testGrowingBasePasses() {
        let cone = (0..<25).map { 20 * pow(1.15, Double($0)) }
        XCTAssertEqual(floatingBases(layers(cone)), [])
        XCTAssertEqual(floatingBases(layers([2500, 2500, 2510, 2520])), [])
    }

    func testSmallJumpPasses() {
        XCTAssertEqual(floatingBases(layers([5, 5, 60])), [])
    }

    func testNamesTheObject() {
        let text = layers([3000, 3000], label: 101) + "\n" + layers([10, 10, 10, 3000], label: 102)
        let problems = floatingBases(text, names: [101: "lid", 102: "pinned box"])
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].hasPrefix("pinned box prints its base in the air"))
    }

    func testOnlyLooksAtTheBottom() {
        XCTAssertEqual(floatingBases(layers(Array(repeating: 10, count: 40) + [3000])), [])
    }
}

final class MachineTests: XCTestCase {
    func testSerialGuess() {
        XCTAssertEqual(Machine.guess(serial: "0309DA000000000"), "A1 mini")
        XCTAssertEqual(Machine.guess(serial: "01p00a000000000"), "P1S")
        XCTAssertEqual(Machine.guess(serial: "00M09A000000000"), "X1 Carbon")
        XCTAssertNil(Machine.guess(serial: "ZZZ"))
    }

    func testCamera() {
        XCTAssertTrue(Machine(model: "A1 mini").hasCamera)
        XCTAssertFalse(Machine(model: "X1 Carbon").hasCamera)
    }

    func testEnv() {
        let kv = PrinterConfig.parseEnv("PRINTER_IP=1.2.3.4\nexport PRINTER_MODEL=\"A1 mini\"\n# x=y\n")
        XCTAssertEqual(kv["PRINTER_IP"], "1.2.3.4")
        XCTAssertEqual(kv["PRINTER_MODEL"], "A1 mini")
        XCTAssertNil(kv["# x"])
    }

    func testProfilesForEveryModel() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Paths.profiles), "needs Bambu Studio")
        for model in ["A1 mini", "A1", "A2L", "P1S", "X1 Carbon", "X1E", "H2D", "H2S", "P2S"] {
            let m = Machine(model: model)
            XCTAssertNoThrow(try loadProfile("machine", m.profile), model)
            XCTAssertNoThrow(try resolveProfile("filament", "Bambu PLA Basic", for: m), model)
            XCTAssertNoThrow(try resolveProfile("filament", "Generic PETG", for: m), model)
            XCTAssertTrue(layerProfiles(for: m).contains { $0.height == "0.20" }, model)
            XCTAssertEqual(defaultLayer(for: m), "0.20", model)
        }
        XCTAssertEqual(try resolveProfile("filament", "PolyTerra PLA", for: Machine(model: "A1 mini")), "PolyTerra PLA @BBL A1M")
        XCTAssertEqual(try resolveProfile("filament", "Bambu PLA Silk @BBL A1M", for: Machine(model: "A1 mini")), "Bambu PLA Silk @BBL A1M")
        XCTAssertEqual(layerProfiles(for: Machine(model: "A1 mini")).first { $0.height == "0.20" }?.profile, "0.20mm Standard @BBL A1M")
        XCTAssertThrowsError(try resolveProfile("filament", "Nonexistent PLA", for: Machine(model: "P1S")))
    }
}

final class ReportTests: XCTestCase {
    func testCodes() {
        let r = Report(["hms": [["attr": 0x0300_0200, "code": 0x0001_000A]], "print_error": 0x0300_400C])
        XCTAssertEqual(r.hms, ["HMS_0300_0200_0001_000A"])
        XCTAssertEqual(r.error, "0300_400C")
    }

    func testMQTTLength() {
        XCTAssertEqual(packet(0x30, Data(count: 200)).prefix(3), Data([0x30, 0xC8, 0x01]))
    }
}

final class PlateTests: XCTestCase {
    func fp(_ whole: [Float], _ tiles: [[Float]]) -> Plate.Fingerprint { Plate.Fingerprint(whole: whole, tiles: tiles, key: nil) }

    func testDecisions() {
        let empty = fp([1, 0], [[1, 0], [1, 0]])
        XCTAssertEqual(Plate.decide(empty, empties: [], busies: []).verdict, "unknown")
        XCTAssertEqual(Plate.decide(fp([0.99, 0.14], [[1, 0], [0.99, 0.14]]), empties: [empty], busies: []).verdict, "clear")
        XCTAssertEqual(Plate.decide(fp([0.99, 0.14], [[1, 0], [0.8, 0.6]]), empties: [empty], busies: []).verdict, "busy")
        XCTAssertEqual(Plate.decide(fp([0.7, 0.71], [[1, 0], [1, 0]]), empties: [empty], busies: [fp([0.6, 0.8], [])]).verdict, "busy")
        let other = fp([0, 1], [[0, 1], [0, 1]])
        XCTAssertEqual(Plate.decide(fp([0.1, 0.99], [[0, 1], [0, 1]]), empties: [empty, other], busies: []).verdict, "clear")
    }

    func testTOML() throws {
        let t = try parseTOML("[pla-silk]\nprofile = \"Bambu PLA Silk @BBL A1M\"  # shiny\nnozzle = 225\n")
        XCTAssertEqual(t.first?.0, "pla-silk")
        XCTAssertEqual(t.first?.1["nozzle"], "225")
        XCTAssertEqual(t.first?.1["profile"], "Bambu PLA Silk @BBL A1M")
    }
}
