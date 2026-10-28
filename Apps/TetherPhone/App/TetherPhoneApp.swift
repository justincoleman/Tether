import SwiftUI
import TetherProtocol

@main
struct TetherPhoneApp: App {
    @State private var store = PhoneStore()
    @State private var showPairing = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            OverviewView(showPairing: $showPairing)
                .environment(store)
                .sheet(isPresented: $showPairing) {
                    PairView().environment(store)
                }
                // The Camera app opens tether://pair links from the Mac's QR.
                .onOpenURL { url in
                    guard let link = PairingLink(url: url) else { return }
                    store.pair(link)
                    showPairing = true
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // iOS suspends sockets in the background; reconnect on return.
                    switch phase {
                    case .active: store.connectAll()
                    case .background: store.disconnectAll()
                    default: break
                    }
                }
        }
    }
}
