import CoreGraphics
import Eye
import Foundation
import ImageIO

public enum Plate {
    public static let crop = CGRect(x: 0, y: 0.3, width: 1, height: 0.7)
    public static let grid = (cols: 4, rows: 2)
    public static let clearMin = 0.93
    public static var tileClear = 0.95
    public static var tileBusy = 0.90
    static var key: String { "\(crop.minX),\(crop.minY),\(crop.width),\(crop.height) grid \(grid.cols)x\(grid.rows)" }

    nonisolated(unsafe) static var eye: Eye?

    public struct Fingerprint: Codable {
        public let whole: [Float]
        public let tiles: [[Float]]
        public var key: String?
    }

    public struct Verdict {
        public let verdict: String
        public let empty: Double?
        public let tile: Double?
        public let tiles: [Double]
        public let busy: Double?
        public let fingerprint: Fingerprint?
        public init(verdict: String, empty: Double?, tile: Double?, tiles: [Double], busy: Double?, fingerprint: Fingerprint?) {
            self.verdict = verdict; self.empty = empty; self.tile = tile; self.tiles = tiles; self.busy = busy; self.fingerprint = fingerprint
        }
        public var why: String {
            guard let e = empty, let t = tile else { return "no reference yet; clear the plate and run: clambu plate learn" }
            return String(format: "%.3f like the empty plate, weakest tile %.3f", e, t)
                + (busy.map { String(format: ", %.3f like a busy plate", $0) } ?? "")
        }
    }

    static func model() async throws -> Eye {
        if let e = eye { return e }
        let e = Eye()
        if !e.isDownloaded() {
            FileHandle.standardError.write("clambu: downloading the Eye model once\n".data(using: .utf8)!)
            try await e.download()
        }
        eye = e
        return e
    }

    static func embed(_ image: CGImage) async throws -> [Float] {
        let a = try await model().analyze(image, options: Options(parts: .photo))
        guard let v = a.embedding else { throw Stop("Eye returned no embedding") }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / (n > 0 ? n : 1) }
    }

    public static func fingerprint(_ path: String) async throws -> Fingerprint {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Stop("cannot read \(path)", .usage) }
        let W = Double(full.width), H = Double(full.height)
        let band = CGRect(x: crop.minX * W, y: crop.minY * H, width: crop.width * W, height: crop.height * H)
        guard let whole = full.cropping(to: band.integral) else { throw Stop("the plate crop is outside the frame") }
        var tiles: [[Float]] = []
        let tw = band.width / Double(grid.cols), th = band.height / Double(grid.rows)
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let r = CGRect(x: band.minX + Double(col) * tw, y: band.minY + Double(row) * th, width: tw, height: th).integral
                guard let t = full.cropping(to: r) else { throw Stop("a plate tile is outside the frame") }
                tiles.append(try await embed(t))
            }
        }
        return Fingerprint(whole: try await embed(whole), tiles: tiles, key: key)
    }

    static func cos(_ a: [Float], _ b: [Float]) -> Double {
        Double(zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 })
    }

    public static func count(_ kind: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: "\(Paths.plate)/\(kind)")) ?? []).filter { $0.hasSuffix(".jpg") }.count
    }

    public static func references(_ kind: String) async throws -> [Fingerprint] {
        let dir = "\(Paths.plate)/\(kind)"
        let jpgs = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
        var out: [Fingerprint] = []
        for j in jpgs {
            let json = URL(fileURLWithPath: "\(dir)/\(j.dropLast(4)).json")
            if let d = try? Data(contentsOf: json), let f = try? JSONDecoder().decode(Fingerprint.self, from: d), f.key == key {
                out.append(f)
            } else {
                let f = try await fingerprint("\(dir)/\(j)")
                try JSONEncoder().encode(f).write(to: json)
                out.append(f)
            }
        }
        return out
    }

    @discardableResult
    public static func remember(_ frame: String, _ kind: String, fingerprint known: Fingerprint? = nil) async throws -> String {
        let dir = "\(Paths.plate)/\(kind)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var stem = "\(dir)/\(timestamp())"
        var n = 2
        while FileManager.default.fileExists(atPath: stem + ".jpg") { stem = "\(dir)/\(timestamp())-\(n)"; n += 1 }
        try FileManager.default.copyItem(atPath: frame, toPath: stem + ".jpg")
        let f: Fingerprint
        if let known { f = known } else { f = try await fingerprint(frame) }
        try JSONEncoder().encode(f).write(to: URL(fileURLWithPath: stem + ".json"))
        return stem + ".jpg"
    }

    public static func decide(_ f: Fingerprint, empties: [Fingerprint], busies: [Fingerprint]) -> Verdict {
        guard let ref = empties.max(by: { cos(f.whole, $0.whole) < cos(f.whole, $1.whole) }) else {
            return Verdict(verdict: "unknown", empty: nil, tile: nil, tiles: [], busy: nil, fingerprint: f)
        }
        let sEmpty = cos(f.whole, ref.whole)
        let tiles = zip(f.tiles, ref.tiles).map { cos($0, $1) }
        let weakest = tiles.min() ?? 0
        let sBusy = busies.map { cos(f.whole, $0.whole) }.max()
        let v: String
        if let b = sBusy, b > sEmpty { v = "busy" }
        else if weakest < tileBusy { v = "busy" }
        else if sEmpty >= clearMin && weakest >= tileClear { v = "clear" }
        else { v = "unsure" }
        return Verdict(verdict: v, empty: sEmpty, tile: weakest, tiles: tiles, busy: sBusy, fingerprint: f)
    }

    public static func judge(_ frame: String) async throws -> Verdict {
        let empties = try await references("empty")
        guard !empties.isEmpty else { return Verdict(verdict: "unknown", empty: nil, tile: nil, tiles: [], busy: nil, fingerprint: nil) }
        return decide(try await fingerprint(frame), empties: empties, busies: try await references("busy"))
    }
}
