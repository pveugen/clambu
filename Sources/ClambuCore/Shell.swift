import Foundation

@discardableResult
public func run(_ exe: String, _ args: [String], cwd: String? = nil, stdin: String? = nil,
                timeout: TimeInterval = 600, passthroughStderr: Bool = false) throws -> (code: Int32, out: Data, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clambu-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let outURL = tmp.appendingPathComponent("out"), errURL = tmp.appendingPathComponent("err")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    let outH = try FileHandle(forWritingTo: outURL), errH = try FileHandle(forWritingTo: errURL)
    p.standardOutput = outH
    p.standardError = passthroughStderr ? FileHandle.standardError : errH
    var inPipe: Pipe?
    if stdin != nil { inPipe = Pipe(); p.standardInput = inPipe }
    do { try p.run() } catch { throw Stop("cannot run \(exe): \(error.localizedDescription)", .setup) }
    if let s = stdin, let pipe = inPipe {
        pipe.fileHandleForWriting.write(s.data(using: .utf8)!)
        try? pipe.fileHandleForWriting.close()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning {
        if Date() > deadline {
            p.terminate()
            throw Stop("\((exe as NSString).lastPathComponent) did not finish within \(Int(timeout))s")
        }
        usleep(50_000)
    }
    try? outH.close(); try? errH.close()
    let out = (try? Data(contentsOf: outURL)) ?? Data()
    let err = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
    return (p.terminationStatus, out, err)
}

public func notify(_ title: String, _ message: String) {
    let clean = { (s: String) in s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "'") }
    _ = try? run("/usr/bin/osascript", ["-e", "display notification \"\(clean(message))\" with title \"\(clean(title))\" sound name \"Glass\""], timeout: 10)
}

public func say(_ s: String) {
    if Output.json {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    } else {
        print(s)
        fflush(stdout)
    }
}

public func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}

public func timeOfDay(_ date: Date = Date(), seconds: Bool = false) -> String {
    let f = DateFormatter()
    f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
    return f.string(from: date)
}
