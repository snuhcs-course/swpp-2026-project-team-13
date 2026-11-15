import Foundation
import Network

// Whether the device has a usable network path. `connected` in AppModel only says a login
// succeeded; it stays true when airplane mode is turned on later.
@MainActor final class NetworkStatus: ObservableObject {
    static let shared = NetworkStatus()
    @Published var online = true
    private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in if NetworkStatus.shared.online != online { NetworkStatus.shared.online = online } }
        }
        monitor.start(queue: DispatchQueue(label: "solfege.network-status"))
    }
}
