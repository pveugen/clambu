import CoreGraphics
import Eye
import Foundation
import ImageIO

public enum Sharp {
    public static func score(_ jpeg: Data) async throws -> Double {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw Stop("cannot read a camera frame")
        }
        let a = try await Plate.model().analyze(img, options: Options(parts: .sharpness))
        guard let s = a.details?.sharpness?.score else { throw Stop("Eye returned no sharpness score") }
        return s
    }

    public struct Pick: Sendable {
        public let frame: Data
        public let score: Double
        public let scores: [Double]
    }

    public static func pick(_ frames: [Data]) async -> Pick {
        guard frames.count > 1 else { return Pick(frame: frames[0], score: -1, scores: []) }
        var scores: [Double] = []
        for f in frames { scores.append((try? await score(f)) ?? -1) }
        let best = scores.indices.max { scores[$0] < scores[$1] } ?? frames.count - 1
        return Pick(frame: frames[best], score: scores[best], scores: scores)
    }
}

public func sharpSnapshot(_ cfg: PrinterConfig, count: Int) async throws -> Sharp.Pick {
    await Sharp.pick(try await frames(cfg, count: count))
}
