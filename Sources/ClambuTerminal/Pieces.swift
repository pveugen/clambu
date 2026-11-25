import ClambuCore
import SwiftTUICLI

func color(_ c: UInt32) -> Color { Color(hexRGB: c) }

struct Line: View {
    let pieces: [Piece]
    init(_ pieces: [Piece]) { self.pieces = pieces }
    init(_ pieces: Piece...) { self.pieces = pieces }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                Text(p.text).foregroundStyle(color(p.color)).bold(p.bold).lineLimit(1).fixedSize()
            }
        }
    }
}

func badge(_ s: PrinterState, connected: Bool = true) -> [Piece] {
    let dot: String
    switch s.state {
    case "PAUSE": dot = "⏸"
    case "FINISH": dot = "✓"
    case "FAILED": dot = "✗"
    default: dot = s.alerts.isEmpty ? "●" : "▲"
    }
    if !connected { return [Piece("● ", Palette.amber), Piece("lost the printer", Palette.amber, bold: true)] }
    return [Piece(dot + " ", Palette.tone(s.tone)), Piece(s.label, Palette.text, bold: true)]
}

func temperature(_ now: Int, _ target: Int) -> [Piece] {
    let arrow = target > now + 3 ? Piece(" ↑", Palette.amber) : (target + 3 < now && target > 0 ? Piece(" ↓", Palette.blue) : Piece("  "))
    return [Piece("\(now)°", Palette.text, bold: true), Piece(target > 0 ? " / \(target)°" : " / off", Palette.dim), arrow]
}

func keys(_ list: [(String, String)]) -> [Piece] {
    var out: [Piece] = []
    for (i, k) in list.enumerated() {
        if i > 0 { out.append(Piece("   ")) }
        out.append(Piece(k.0, Palette.sand, bold: true))
        out.append(Piece(" " + k.1, Palette.dim))
    }
    return out
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

func width(_ pieces: [Piece]) -> Int { pieces.reduce(0) { $0 + $1.text.count } }

func fit(_ options: [[Piece]], _ room: Int) -> [Piece] {
    options.first { width($0) <= room } ?? options.last ?? []
}
