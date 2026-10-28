import SwiftUI
import TetherCore

struct SettingsView: View {
    var body: some View {
        TabView {
            RemoteHostsSettings()
                .tabItem { Label("Remote Hosts", systemImage: "network") }
        }
        .frame(width: 480, height: 320)
    }
}

/// SSH targets offered in the + menu, e.g. the always-on Mac mini.
struct RemoteHostsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var draft = RemoteHost(name: "", host: "", user: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(model.remoteHosts) { host in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(host.name)
                            Text(host.sshTarget).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.removeRemoteHost(host.id) }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                    }
                }
            }
            GroupBox("Add host") {
                HStack {
                    TextField("Name", text: $draft.name)
                    TextField("Host", text: $draft.host)
                    TextField("User", text: Binding(
                        get: { draft.user ?? "" },
                        set: { draft.user = $0.isEmpty ? nil : $0 }))
                    Button("Add") {
                        let host = draft
                        draft = RemoteHost(name: "", host: "", user: nil)
                        Task { await model.addRemoteHost(host) }
                    }
                    .disabled(draft.name.isEmpty || draft.host.isEmpty)
                }
            }
        }
        .padding()
    }
}
