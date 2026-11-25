import Foundation

public struct Event: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case status, state, layer, frame, plate, alert, finished, message, error
    }

    public var kind: Kind
    public var at: Date
    public var message: String
    public var state: PrinterState?
    public var from: String?
    public var to: String?
    public var layer: Int?
    public var path: String?
    public var plate: PlateState?

    public init(_ kind: Kind, _ message: String, at: Date = Date(), state: PrinterState? = nil, from: String? = nil,
                to: String? = nil, layer: Int? = nil, path: String? = nil, plate: PlateState? = nil) {
        self.kind = kind; self.message = message; self.at = at; self.state = state; self.from = from; self.to = to
        self.layer = layer; self.path = path; self.plate = plate
    }

    public var notable: Bool {
        switch kind {
        case .status, .frame: return false
        case .layer:
            guard let l = layer else { return false }
            return l == 1 || l % 10 == 0 || l == state?.totalLayers
        default: return true
        }
    }
}

public struct PlateState: Codable, Sendable, Equatable {
    public var verdict: String
    public var empty: Double?
    public var tile: Double?
    public var at: Date
    public init(_ v: Plate.Verdict, at: Date = Date()) { verdict = v.verdict; empty = v.empty; tile = v.tile; self.at = at }
}

public struct Snapshot: Sendable {
    public var state: PrinterState
    public var history: History
    public var frameAt: Date?
    public var framePath: String?
    public var plate: PlateState?
    public var localURL: String?
    public var tailnetURL: String?
    public var every: Int
    public var log: [Event]
    public var connected: Bool

    public init(state: PrinterState, history: History, frameAt: Date?, framePath: String?, plate: PlateState?, localURL: String?,
                tailnetURL: String?, every: Int, log: [Event], connected: Bool) {
        self.state = state; self.history = history; self.frameAt = frameAt; self.framePath = framePath; self.plate = plate
        self.localURL = localURL; self.tailnetURL = tailnetURL; self.every = every; self.log = log; self.connected = connected
    }
}
