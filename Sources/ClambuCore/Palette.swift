import Foundation

public enum Palette {
    public static let sand: UInt32 = 0xC9A35A
    public static let green: UInt32 = 0x7EC480
    public static let amber: UInt32 = 0xE8A84E
    public static let red: UInt32 = 0xE5604D
    public static let blue: UInt32 = 0x7AA2F7
    public static let text: UInt32 = 0xECEBE8
    public static let dim: UInt32 = 0x8A8985
    public static let faint: UInt32 = 0x4A4A48
    public static let track: UInt32 = 0x343432

    public static func tone(_ t: PrinterState.Tone) -> UInt32 {
        switch t {
        case .good: green
        case .busy: blue
        case .warn: amber
        case .bad: red
        case .done: sand
        case .quiet: dim
        }
    }

    public static func hex(_ c: UInt32) -> String { String(format: "#%06x", c) }

    public static func rgb(_ c: UInt32) -> (Int, Int, Int) { (Int(c >> 16 & 0xFF), Int(c >> 8 & 0xFF), Int(c & 0xFF)) }

    public static func ansi(_ text: String, _ c: UInt32, bold: Bool = false) -> String {
        let (r, g, b) = rgb(c)
        let colored = "\u{1B}[38;2;\(r);\(g);\(b)m\(text)\u{1B}[39m"
        return bold ? "\u{1B}[1m" + colored + "\u{1B}[22m" : colored
    }
}

public struct Piece: Sendable {
    public var text: String
    public var color: UInt32
    public var bold: Bool

    public init(_ text: String, _ color: UInt32 = Palette.text, bold: Bool = false) {
        self.text = text
        self.color = color
        self.bold = bold
    }
}

public func bar(_ fraction: Double, width: Int, color: UInt32 = Palette.sand) -> [Piece] {
    let width = max(1, width)
    let f = min(max(fraction, 0), 1) * Double(width)
    let whole = Int(f)
    let half = f - Double(whole) >= 0.5 && whole < width
    return [Piece(String(repeating: "━", count: whole) + (half ? "╸" : ""), color),
            Piece(String(repeating: "━", count: width - whole - (half ? 1 : 0)), Palette.track)]
}
