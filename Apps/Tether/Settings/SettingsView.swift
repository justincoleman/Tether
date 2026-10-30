import SwiftUI
import TetherCore

struct SettingsView: View {
    /// Which tab the window shows; other views set it before opening Settings.
    @AppStorage("settingsTab") private var tab = "appearance"

    var body: some View {
        TabView(selection: $tab) {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag("appearance")
            PhoneSettings()
                .tabItem { Label("iPhone", systemImage: "iphone") }
                .tag("iphone")
            MacsSettings()
                .tabItem { Label("Macs", systemImage: "desktopcomputer") }
                .tag("macs")
            RemoteHostsSettings()
                .tabItem { Label("SSH Hosts", systemImage: "terminal") }
                .tag("ssh")
            UpdatesSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag("updates")
        }
        .frame(width: 620, height: 600)
    }
}

/// Whether the window follows the Ghostty theme or the system appearance.
struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance: AppearanceMode = .terminal
    @AppStorage("useProjectIcons") private var useProjectIcons = true
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("showLimitRings") private var showLimitRings = true
    @AppStorage("showLimitPace") private var showLimitPace = true
    @AppStorage("inactiveAfterDays") private var inactiveAfterDays = ProjectActivity.defaultInactiveAfterDays

    var body: some View {
        Form {
            Picker("Window colors", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            Text("Match terminal theme colors the sidebar, tabs and panels from your Ghostty theme. "
                 + "The terminal itself always uses your Ghostty config.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show each project's app icon in the sidebar and on the iPhone", isOn: $useProjectIcons)
                .onChange(of: useProjectIcons) { model.companion.sendProjectIcons() }
            Text("Looks for .tether/icon.png, then an Xcode AppIcon, then a favicon or logo in the project folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper("Move projects to Inactive after \(inactiveAfterDays) day\(inactiveAfterDays == 1 ? "" : "s") without use",
                    value: $inactiveAfterDays, in: 1...60)
                .onChange(of: inactiveAfterDays) { model.companion.setNeedsSnapshot() }
            Text("Sending a prompt, opening a tab, or Claude working in the project counts as use, and so does "
                 + "Claude Code run outside Tether. Pinned projects stay Active.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("New Claude tabs open as", selection: Binding(
                get: { model.chatByDefault }, set: { model.setChatByDefault($0) })) {
                Text("Terminal").tag(false)
                Text("Chat").tag(true)
            }
            .pickerStyle(.radioGroup)
            Text("Each tab can be switched from the buttons in the tab bar or View > Show as Chat. "
                 + "Claude keeps running in the terminal either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show plan limits at the bottom of the sidebar", isOn: $showLimitRings)
            Toggle("Mark how far into each window you are", isOn: $showLimitPace)
                .disabled(!showLimitRings)
            Text("Rings for the 5-hour and weekly limits. The tick on each ring is the time that has passed; a ring "
                 + "that's past its tick is using the limit faster than it refills. Claude Code reports them after each reply.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show Tether in the menu bar", isOn: $showMenuBarExtra)
            Text("Lists every Claude tab and what it's doing, with a count of the ones waiting on you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !TerminalHost.configWarnings.isEmpty {
                Section("Ghostty config") {
                    ForEach(TerminalHost.configWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                }
            }
        }
        .padding()
    }
}

/// SSH targets offered on the start page (+), e.g. the always-on Mac mini. Not for
/// pairing another Mac: that is Settings → Macs.
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
            if draft.name.hasPrefix("tether://") || draft.host.hasPrefix("tether://") || (draft.user ?? "").hasPrefix("tether://") {
                Label("That's a pairing link, not an SSH host. Paste it in Settings → Macs.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
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
                    .disabled(draft.name.isEmpty || draft.host.isEmpty || draft.host.hasPrefix("tether://"))
                }
            }
        }
        .padding()
    }
}
