import Connect
import Foundation

/// A failed API call, reduced to the distinctions the app acts on.
public struct APIError: Error, Sendable, CustomStringConvertible {
    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    init(_ error: ConnectError) {
        self.init(code: error.code, message: error.message ?? "")
    }

    /// The request never got an answer: no network, DNS failure, timeout or a dropped connection.
    public var isConnectivity: Bool {
        switch code {
        // Not `.canceled`: that's this app cancelling its own request, not the network.
        case .unavailable, .deadlineExceeded: true
        case .unknown: message.localizedCaseInsensitiveContains("offline") || message.localizedCaseInsensitiveContains("connection")
        default: false
        }
    }

    /// The session is gone and only signing in again will help.
    public var isSessionExpired: Bool { code == .unauthenticated }

    public var description: String { message.isEmpty ? "\(code)" : message }

    public static let sessionExpired = APIError(code: .unauthenticated, message: String(localized: "Your session has expired. Sign in again.", bundle: .module))
}
