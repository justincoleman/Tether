import SwiftUI
import TetherProtocol

@main
struct TetherPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentUnavailableView(
                    "No Macs paired",
                    systemImage: "qrcode.viewfinder",
                    description: Text("Pairing arrives in phase 5. Protocol v\(ProtocolVersion.current).")
                )
                .navigationTitle("Overview")
            }
        }
    }
}
