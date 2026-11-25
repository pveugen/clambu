import ArgumentParser
import ClambuCore
import ClambuTerminal
import Foundation

struct RenderMock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "render-mock", shouldDisplay: false)
    @Argument(help: "panel, follow or hud") var view = "follow"
    @Option var scene = "printing"
    @Option var width = 120
    @Flag var noColor = false
    func run() async throws {
        guard let sc = Render.Scene(rawValue: scene) else { throw Stop("scene must be one of \(Render.Scene.allCases.map(\.rawValue).joined(separator: ", "))", .usage) }
        let text: String = await MainActor.run {
            switch view {
            case "panel": Render.panel(sc, width: width, color: !noColor)
            case "hud": HUD.preview(Render.snapshot(sc, now: Date()), width: width)
            default: Render.follow(sc, width: width, color: !noColor)
            }
        }
        print(text)
    }
}
