import Foundation

public func terminalSize() -> (Int, Int) {
    var w = winsize()
    if ioctl(1, TIOCGWINSZ, &w) == 0, w.ws_col > 0 { return (Int(w.ws_col), Int(w.ws_row)) }
    return (100, 34)
}
