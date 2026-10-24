import Foundation
import Network

/// iPadOS does not provide a "show local-network permission" API.
/// Start a minimal, declared Bonjour browse on first foreground activation so
/// the system can present its own authorization prompt before printer setup.
/// This does not connect to or transmit any order data to discovered devices.
@MainActor
final class LocalNetworkPermissionPrimer {
    static let shared = LocalNetworkPermissionPrimer()
    private let queue = DispatchQueue(label: "app.oupos.local-network-permission")
    private var browser: NWBrowser?
    private var hasStarted = false

    func requestAtLaunch() {
        guard !hasStarted else { return }
        hasStarted = true
        let candidate = NWBrowser(for: .bonjour(type: "_ipp._tcp", domain: nil), using: .tcp)
        browser = candidate
        candidate.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready, .failed:
                Task { @MainActor [weak self] in self?.stopBrowsing() }
            default:
                break
            }
        }
        candidate.start(queue: queue)
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }
}
