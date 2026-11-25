import Foundation
import Network

final class TLSSocket: @unchecked Sendable {
    let conn: NWConnection
    private let queue = DispatchQueue(label: "clambu.tls")
    private var buffer = Data()

    init(host: String, port: UInt16) {
        let tls = NWProtocolTLS.Options()
        // The printer uses a self-signed certificate on the LAN, so there is nothing to verify against.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                            using: NWParameters(tls: tls, tcp: tcp))
    }

    func open(timeout: TimeInterval = 12) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { c.resume() }
                case .failed(let e), .waiting(let e): once.run { c.resume(throwing: e) }
                case .cancelled: once.run { c.resume(throwing: Stop("connection cancelled", .unreachable)) }
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.run { c.resume(throwing: Stop("timed out", .unreachable)) } }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    func read(_ n: Int) async throws -> Data {
        while buffer.count < n {
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                conn.receive(minimumIncompleteLength: 1, maximumLength: max(65536, n - buffer.count)) { data, _, done, err in
                    if let err { c.resume(throwing: err) }
                    else if let data, !data.isEmpty { c.resume(returning: data) }
                    else if done { c.resume(throwing: Stop("the printer closed the connection", .unreachable)) }
                    else { c.resume(returning: Data()) }
                }
            }
            buffer.append(chunk)
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(out)
    }

    func close() { conn.cancel() }
}

final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !done { done = true; f() }
    }
}

public func portOpen(_ host: String, _ port: UInt16, timeout: TimeInterval = 3) -> Bool {
    let sem = DispatchSemaphore(value: 0)
    let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let ok = Box(false)
    c.stateUpdateHandler = { s in
        switch s {
        case .ready: ok.value = true; sem.signal()
        case .failed, .waiting: sem.signal()
        default: break
        }
    }
    c.start(queue: .global())
    _ = sem.wait(timeout: .now() + timeout)
    c.cancel()
    return ok.value
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
