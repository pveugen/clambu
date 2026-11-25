import ClambuCore
import CoreGraphics
import Foundation
import ImageIO

public enum InlineImage {
    @MainActor public static func show(path: String) async {
        guard isatty(1) != 0, let seq = sequence(path: path, cols: min(56, terminalSize().0 - 4)) else { return }
        FileHandle.standardOutput.write(Data((seq + "\n").utf8))
    }

    static func sequence(path: String, cols: Int, graphics: Graphics = .detect()) -> String? {
        guard cols > 8, let jpeg = FileManager.default.contents(atPath: path) else { return nil }
        switch graphics {
        case .kitty:
            guard let png = png(jpeg) else { return nil }
            let b64 = Array(png.base64EncodedString())
            var out = ""
            var i = 0
            while i < b64.count {
                let chunk = String(b64[i..<min(i + 4096, b64.count)])
                let more = i + 4096 < b64.count ? 1 : 0
                out += i == 0 ? "\u{1B}_Ga=T,f=100,c=\(cols),q=2,m=\(more);\(chunk)\u{1B}\\" : "\u{1B}_Gm=\(more);\(chunk)\u{1B}\\"
                i += 4096
            }
            return out
        case .iterm:
            return "\u{1B}]1337;File=inline=1;width=\(cols);preserveAspectRatio=1;size=\(jpeg.count):\(jpeg.base64EncodedString())\u{07}"
        case .none:
            return nil
        }
    }

    static func png(_ jpeg: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}

enum Graphics {
    case kitty, iterm, none

    static func detect(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Graphics {
        if env["TMUX"] != nil || env["STY"] != nil { return .none }
        let program = env["TERM_PROGRAM"] ?? "", term = env["TERM"] ?? ""
        if program == "ghostty" || term.contains("kitty") || term.contains("ghostty") || env["KITTY_WINDOW_ID"] != nil { return .kitty }
        if program == "iTerm.app" || program == "WezTerm" { return .iterm }
        return .none
    }
}
