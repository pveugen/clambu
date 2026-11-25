import ClambuCore
import Foundation
import Testing
@testable import ClambuTerminal

@MainActor
struct RenderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func panelFitsItsWidth() {
        for width in [60, 84, 120] {
            let text = Render.panel(.printing, width: width, color: false, now: now)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.count == 5)
            for l in lines { #expect(l.count <= width) }
            #expect(text.contains("printing"))
            #expect(text.contains("62%"))
            #expect(text.contains("q quit"))
        }
    }

    @Test func panelShortensKeysWhenNarrow() {
        #expect(Render.panel(.printing, width: 120, color: false, now: now).contains("c frame"))
        #expect(!Render.panel(.printing, width: 70, color: false, now: now).contains("c frame"))
    }

    @Test func idlePanelHasNoBar() {
        let text = Render.panel(.idle, width: 100, color: false, now: now)
        #expect(!text.contains("━"))
        #expect(text.contains("plate clear"))
    }

    @Test func heatingSaysSo() {
        let text = Render.panel(.heating, width: 100, color: false, now: now)
        #expect(text.contains("heating"))
        #expect(!text.contains("layer 0"))
    }

    @Test func alertsShow() {
        #expect(Render.panel(.alert, width: 100, color: false, now: now).contains("▲ HMS_"))
        #expect(Render.panel(.lost, width: 100, color: false, now: now).contains("lost the printer"))
    }

    @Test func followShowsTheLogAboveThePanel() {
        let text = Render.follow(.printing, width: 100, color: false, now: now)
        #expect(text.contains("layer 1 of 290"))
        #expect(text.hasSuffix(Render.panel(.printing, width: 99, color: false, now: now)))
    }

    @Test func keysAskBeforePausing() {
        let m = PanelModel(snapshot: Render.snapshot(.printing, now: now), now: now)
        m.key("p")
        #expect(m.ask == .pause)
        m.key("n")
        #expect(m.ask == nil)
        #expect(m.message == "cancelled")
        m.key("r")
        #expect(m.message == "nothing to resume")
        m.key("x")
        #expect(m.ask == .stop)
    }
}
