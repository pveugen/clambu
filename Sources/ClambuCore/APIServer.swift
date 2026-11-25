import Foundation
import Network

public struct APIStatus: Codable, Sendable {
    public var connected: Bool
    public var state: PrinterState
    public var plate: PlateState?
    public var frameAt: Date?
    public var every: Int
    public var history: History
    public var url: String?
    public var tailnetURL: String?
    public var log: [Event]

    public init(_ s: Snapshot, logCount: Int = 50) {
        connected = s.connected; state = s.state; plate = s.plate; frameAt = s.frameAt; every = s.every
        history = s.history; url = s.localURL; tailnetURL = s.tailnetURL; log = Array(s.log.suffix(logCount))
    }
}

final class APIServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "clambu.api")
    weak var monitor: Monitor?
    private(set) var port: UInt16 = 0

    init(monitor: Monitor, host: String = "127.0.0.1", port wanted: UInt16) throws {
        self.monitor = monitor
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: wanted) ?? .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start() -> UInt16? {
        let ready = DispatchSemaphore(value: 0)
        let ok = Box(false)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ok.value = true; self?.port = self?.listener.port?.rawValue ?? 0; ready.signal()
            case .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        return ok.value ? port : nil
    }

    func stop() { listener.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let monitor = self.monitor, let data, let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first else { c.cancel(); return }
            let parts = line.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "/") : "/"
            guard method == "GET" || method == "HEAD" else {
                self.reply(c, "text/plain", Data("clambu's API is read-only\n".utf8), code: "405 Method Not Allowed")
                return
            }
            switch path {
            case "/":
                self.reply(c, "text/html; charset=utf-8", Data(WebPage.html.utf8))
            case "/api/status":
                self.reply(c, "application/json", Data(JSON.string(APIStatus(monitor.snapshot()), pretty: false).utf8))
            case "/api/frame.jpg":
                if let f = monitor.latestFrame { self.reply(c, "image/jpeg", f) }
                else { self.reply(c, "text/plain", Data("no frame yet\n".utf8), code: "404 Not Found") }
            case "/api/events":
                self.stream(c, monitor)
            case "/favicon.ico":
                self.reply(c, "text/plain", Data(), code: "204 No Content")
            default:
                self.reply(c, "text/plain", Data("not found\n".utf8), code: "404 Not Found")
            }
        }
    }

    private func reply(_ c: NWConnection, _ type: String, _ body: Data, code: String = "200 OK") {
        let head = "HTTP/1.1 \(code)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func stream(_ c: NWConnection, _ monitor: Monitor) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n"
        let events = monitor.events()
        let first = Event(.status, monitor.snapshot().state.label, state: monitor.snapshot().state)
        Task.detached {
            guard await Self.send(c, Data(head.utf8) + Self.sse(first)) else { c.cancel(); return }
            for await e in events {
                guard await Self.send(c, Self.sse(e)) else { break }
            }
            c.cancel()
        }
    }

    static func sse(_ e: Event) -> Data {
        Data("event: \(e.kind == .error ? "problem" : e.kind.rawValue)\ndata: \(JSON.string(e, pretty: false))\n\n".utf8)
    }

    static func send(_ c: NWConnection, _ d: Data) async -> Bool {
        await withCheckedContinuation { k in
            c.send(content: d, completion: .contentProcessed { err in k.resume(returning: err == nil) })
        }
    }
}

func tailscaleSelf() -> (name: String, ip: String)? {
    for exe in ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
    where FileManager.default.isExecutableFile(atPath: exe) {
        guard let r = try? run(exe, ["status", "--json"], timeout: 5), r.code == 0,
              let json = try? JSONSerialization.jsonObject(with: r.out) as? [String: Any],
              let me = json["Self"] as? [String: Any], (me["Online"] as? Bool) != false,
              let ip = (me["TailscaleIPs"] as? [String])?.first(where: { $0.contains(".") }) else { continue }
        let name = (me["DNSName"] as? String)?.split(separator: ".").first.map(String.init) ?? ip
        return (name, ip)
    }
    return nil
}
