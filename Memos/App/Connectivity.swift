import Network
import SwiftUI

/// Watches the network path. Offline, the app shows “Offline” under the title and nothing that
/// needs the server is attempted.
@Observable
final class Connectivity {
    private(set) var isOnline = true
    /// Cellular or a hotspot: the daily full comparison waits for Wi-Fi.
    private(set) var isExpensive = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored var onChange: ((Bool, Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = Self.handler { [weak self] online, expensive in
            guard let self, self.isOnline != online || self.isExpensive != expensive else { return }
            self.isOnline = online
            self.isExpensive = expensive
            self.onChange?(online, expensive)
        }
        monitor.start(queue: DispatchQueue(label: "app.memos.connectivity"))
    }

    /// Built away from the main actor: the monitor calls it on its own queue.
    private nonisolated static func handler(_ update: @escaping @MainActor (Bool, Bool) -> Void) -> @Sendable (NWPath) -> Void {
        { path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in update(online, expensive) }
        }
    }

    func stop() {
        monitor.cancel()
    }
}
