import Foundation

func curl(_ cfg: PrinterConfig, _ args: [String], timeout: TimeInterval, progress: Bool = false) throws -> Data {
    // The access code goes in on stdin, never in the arguments, where ps would show it.
    let r = try run("/usr/bin/curl", ["-sS", "-k", "--connect-timeout", "10", "-K", "-"] + (progress ? ["-#"] : []) + args,
                    stdin: "user = \"bblp:\(cfg.accessCode)\"\n", timeout: timeout, passthroughStderr: progress)
    if r.code != 0 { throw Stop("file transfer failed (curl \(r.code)): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))", .unreachable) }
    return r.out
}

public func upload(_ cfg: PrinterConfig, _ path: String, as name: String) throws {
    _ = try curl(cfg, ["-T", path, "ftps://\(cfg.ip):990/\(name)"], timeout: 600, progress: true)
}

public func listFiles(_ cfg: PrinterConfig, _ path: String = "/") throws -> String {
    let p = path.hasSuffix("/") ? path : path + "/"
    return String(decoding: try curl(cfg, ["ftps://\(cfg.ip):990\(p.hasPrefix("/") ? p : "/" + p)"], timeout: 60), as: UTF8.self)
}

public func snapshot(_ cfg: PrinterConfig) async throws -> Data {
    try await frames(cfg, count: 1)[0]
}

public func frames(_ cfg: PrinterConfig, count: Int) async throws -> [Data] {
    guard cfg.machine.hasCamera else { throw Stop("clambu can read the camera of the A1, A1 mini, A2L, P1P and P1S, not yet the \(cfg.machine.model)'s", .setup) }
    let s = TLSSocket(host: cfg.ip, port: 6000)
    do { try await s.open() } catch { throw Stop("cannot reach the camera at \(cfg.ip):6000 (\(error))", .unreachable) }
    defer { s.close() }
    // Camera handshake: 0x40, 0x3000, 0, 0 as little-endian UInt32, then user and access code padded to 32 bytes.
    var auth = Data()
    for v: UInt32 in [0x40, 0x3000, 0, 0] { withUnsafeBytes(of: v.littleEndian) { auth.append(contentsOf: $0) } }
    func field(_ s: String) -> Data { var d = Data(s.utf8.prefix(32)); d.append(Data(count: 32 - d.count)); return d }
    try await s.send(auth + field("bblp") + field(cfg.accessCode))
    var out: [Data] = []
    while out.count < max(1, count) {
        let head = try await s.read(16)
        let size = Int(head[0]) | Int(head[1]) << 8 | Int(head[2]) << 16 | Int(head[3]) << 24
        guard size > 0 && size < 20_000_000 else { throw Stop("the camera sent an odd frame size (\(size))", .unreachable) }
        let img = try await s.read(size)
        guard img.starts(with: [0xFF, 0xD8]) else { throw Stop("the camera did not send a JPEG", .unreachable) }
        out.append(img)
    }
    return out
}

public func saveSnap(_ cfg: PrinterConfig, _ name: String, best: Int = 1) async throws -> String {
    try FileManager.default.createDirectory(atPath: Paths.snaps, withIntermediateDirectories: true)
    let path = "\(Paths.snaps)/\(timestamp())-\(name).jpg"
    try await sharpSnapshot(cfg, count: best).frame.write(to: URL(fileURLWithPath: path))
    return path
}

public struct FileEntry: Codable, Sendable, Equatable {
    public var name: String
    public var size: Int
    public var directory: Bool
    public var modified: String
}

public func parseListing(_ text: String) -> [FileEntry] {
    text.split(whereSeparator: \.isNewline).compactMap { raw in
        let f = raw.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard f.count == 9, let size = Int(f[4]) else { return nil }
        return FileEntry(name: String(f[8]), size: size, directory: f[0].hasPrefix("d"), modified: "\(f[5]) \(f[6]) \(f[7])")
    }
}
