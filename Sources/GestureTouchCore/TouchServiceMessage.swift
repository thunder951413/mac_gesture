import Foundation

public struct TouchServiceMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case ready, frame, error }

    public let kind: Kind
    public let timestamp: Double?
    public let touches: [ActiveTouch]?
    public let message: String?

    public init(kind: Kind, timestamp: Double? = nil, touches: [ActiveTouch]? = nil, message: String? = nil) {
        self.kind = kind
        self.timestamp = timestamp
        self.touches = touches
        self.message = message
    }
}
