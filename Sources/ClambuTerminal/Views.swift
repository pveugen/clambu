import ClambuCore
import Foundation
import SwiftTUICLI

func heat(_ s: PrinterState) -> Double {
    func part(_ now: Int, _ target: Int) -> Double { target > 25 ? min(1, max(0, Double(now - 25) / Double(target - 25))) : 1 }
    return (part(s.nozzle, s.nozzleTarget) + part(s.bed, s.bedTarget)) / 2
}

struct PanelView: View {
    let model: PanelModel
    let width: Int

    var body: some View {
        let s = model.snap.state
        let left = [Piece(" ")] + badge(s, connected: model.snap.connected) + [Piece("  "), Piece(String(s.job.prefix(max(8, width / 4))), Palette.text)]
        let right = fit(rights(s), width - ClambuTerminal.width(left) - 2)
        let temps = fit(tempRows(s), width - 1)
        VStack(alignment: .leading, spacing: 0) {
            Text(String(repeating: "─", count: width)).foregroundStyle(color(Palette.faint))
            HStack(spacing: 0) {
                Line(left)
                Spacer(minLength: 1)
                Line(right)
            }
            .frame(width: width)
            if s.busy {
                Line([Piece(" ")] + bar(s.state == "PREPARE" ? heat(s) : Double(s.percent ?? 0) / 100, width: width - 2,
                                        color: s.state == "PAUSE" ? Palette.amber : (s.state == "PREPARE" ? Palette.blue : Palette.sand)))
            }
            Line(temps)
            if let a = model.ask {
                Line(Piece(" " + a.question + "  ", Palette.amber, bold: true), Piece("y", Palette.sand, bold: true), Piece(" yes   ", Palette.dim),
                     Piece("n", Palette.sand, bold: true), Piece(" no", Palette.dim))
            } else if !model.status.isEmpty {
                Text(" " + String(model.status.prefix(width - 2))).foregroundStyle(color(Palette.dim))
            } else {
                Line(fit(PanelView.keyLists.map { [Piece(" ")] + keys($0) }, width))
            }
        }
        .frame(width: width, alignment: .leading)
    }

    func rights(_ s: PrinterState) -> [[Piece]] {
        guard s.busy else { return [[Piece(timeOfDay(model.now) + " ", Palette.dim)]] }
        if s.state == "PREPARE" {
            return [[Piece("heating to \(s.nozzleTarget)°", Palette.dim), Piece(" ")], [Piece("")]]
        }
        let pct = Piece("\(s.percent ?? 0)%", Palette.text, bold: true)
        let layer = s.layer.flatMap { l in s.totalLayers.map { Piece("  layer \(l) of \($0)", Palette.dim) } }
        let left = s.remaining.map { Piece("  ·  \($0) left", Palette.dim) }
        let done = s.finishAt.map { [Piece("  ·  done ", Palette.dim), Piece(timeOfDay($0), Palette.text, bold: true)] } ?? []
        let doneShort = s.finishAt.map { [Piece("  done ", Palette.dim), Piece(timeOfDay($0), Palette.text, bold: true)] } ?? []
        return [
            [pct] + [layer, left].compactMap { $0 } + done + [Piece(" ")],
            [pct] + [layer].compactMap { $0 } + done + [Piece(" ")],
            [pct] + doneShort + [Piece(" ")],
            [pct, Piece(" ")],
        ]
    }

    func tempRows(_ s: PrinterState) -> [[Piece]] {
        let noz = [Piece(" nozzle ", Palette.dim)] + temperature(s.nozzle, s.nozzleTarget)
        let bed = [Piece("  bed ", Palette.dim)] + temperature(s.bed, s.bedTarget)
        var extra: [Piece] = []
        if s.busy, let sp = s.speed { extra += [Piece("  speed ", Palette.dim), Piece(sp, Palette.text)] }
        if let p = model.snap.plate, !s.busy {
            extra += [Piece("  plate ", Palette.dim), Piece(p.verdict, p.verdict == "clear" ? Palette.green : Palette.amber)]
        }
        let alerts = s.alerts.map { Piece("  ▲ \($0)", Palette.red) }
        let link = (model.snap.tailnetURL ?? model.snap.localURL).map { [Piece("    "), Piece($0, Palette.blue)] } ?? []
        let short = [Piece(" \(s.nozzle)°", Palette.text, bold: true), Piece(" nozzle", Palette.dim),
                     Piece("  \(s.bed)°", Palette.text, bold: true), Piece(" bed", Palette.dim)]
        return [noz + bed + extra + alerts + link, noz + bed + extra + alerts, noz + bed + alerts, short + alerts, short]
    }

    static let keyLists = [
        [("p", "pause"), ("r", "resume"), ("1-4", "speed"), ("c", "frame"), ("o", "web page"), ("x", "stop"), ("q", "quit")],
        [("p", "pause"), ("r", "resume"), ("1-4", "speed"), ("x", "stop"), ("q", "quit")],
        [("p", "pause"), ("r", "resume"), ("x", "stop"), ("q", "quit")],
    ]
}

