import SwiftUI
import TetherProtocol

/// Start Claude on something from the phone: pick a Mac and project,
/// optionally a new branch (its own worktree), and describe the task.
struct NewTaskView: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var initialMacId: UUID?
    var initialProjectId: ProjectID?
    /// Called with the new tab so the overview can open it.
    let opened: (SessionRoute) -> Void

    @State private var macId: UUID?
    @State private var projectId: ProjectID?
    @State private var onBranch = false
    @State private var branch = ""
    @State private var prompt = ""
    /// Nil starts Claude in the mode from the Mac's Claude Code settings.
    @State private var mode: String?
    @State private var error: String?
    @State private var starting = false

    private var online: [MacConnection] {
        store.connections.filter { $0.status == .online && $0.snapshot != nil }
    }

    private var connection: MacConnection? {
        online.first { $0.id == macId } ?? online.first
    }

    private var projects: [ProjectSummary] { connection?.snapshot?.projects ?? [] }

    private var theme: PhoneTheme { .resolved(connection?.snapshot?.theme) }

    private var canStart: Bool {
        !starting && connection != nil && projectId != nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!onBranch || !branch.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if online.isEmpty {
                        Text("No Mac is online. Check Tailscale and that Tether is running.")
                            .foregroundStyle(.secondary)
                    } else {
                        if online.count > 1 {
                            Picker("Mac", selection: Binding(get: { connection?.id }, set: { macId = $0 })) {
                                ForEach(online) { Text($0.mac.name).tag(Optional($0.id)) }
                            }
                        }
                        Picker("Project", selection: $projectId) {
                            ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Section {
                            Toggle("On a new branch", isOn: $onBranch)
                            if onBranch {
                                TextField("Branch name, e.g. fix-login", text: $branch)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        } footer: {
                            Text(onBranch
                                 ? "The Mac creates a separate worktree, so this doesn't touch the main checkout."
                                 : "Runs in the project's main folder, next to any open tabs.")
                        }
                        Section("Task") {
                            TextField("What should Claude do?", text: $prompt, axis: .vertical)
                                .lineLimit(4...12)
                        }
                        Section {
                            Picker("Mode", selection: $mode) {
                                Text("Default from settings").tag(String?.none)
                                ForEach(PermissionModeName.launchable, id: \.self) { m in
                                    Text(PermissionModeName.label(m)).tag(Optional(m))
                                }
                            }
                        } footer: {
                            Text(PermissionModeName.explanation(mode))
                        }
                        if let error {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
                .listRowBackground(theme.card)
            }
            .macColors(connection?.snapshot?.theme)
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView()
                    } else {
                        Button("Start", action: start).disabled(!canStart)
                    }
                }
            }
            .onAppear {
                macId = macId ?? initialMacId
                projectId = projectId ?? initialProjectId ?? projects.first?.id
            }
            .onChange(of: connection?.id) { old, _ in
                if old != nil { projectId = projects.first?.id }
            }
        }
    }

    private func start() {
        guard let connection, let projectId else { return }
        starting = true
        error = nil
        let branchName = onBranch ? branch.trimmingCharacters(in: .whitespaces) : nil
        Task {
            switch await connection.startSession(projectId: projectId, branch: branchName, prompt: prompt,
                                                 permissionMode: mode) {
            case .started(let paneId):
                dismiss()
                opened(SessionRoute(macId: connection.id, paneId: paneId))
            case .failed(let message):
                error = message
            }
            starting = false
        }
    }
}

/// Drag to reorder a Mac's projects, tap the pencil to rename one. The
/// Mac's sidebar follows.
struct ReorderProjectsView: View {
    let connection: MacConnection
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [ProjectSummary] = []
    @State private var renaming: ProjectSummary?
    @State private var newName = ""

    private var theme: PhoneTheme { .resolved(connection.snapshot?.theme) }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    ForEach(projects) { project in
                        HStack {
                            ProjectTile(name: project.name, icon: connection.projectIcons[project.id])
                            Text(project.name)
                            Spacer()
                            Button {
                                newName = project.name
                                renaming = project
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Rename \(project.name)")
                        }
                        .moveDisabled(!project.pinned)
                    }
                    .onMove { projects.move(fromOffsets: $0, toOffset: $1) }
                }
                .listRowBackground(theme.card)
                if projects.contains(where: \.pinned) {
                    Text("Drag pinned projects to set their order. The rest sort themselves by recent use.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .listRowBackground(Color.clear)
                } else {
                    Text("Pin a project (long-press it) to keep it at the top in your own order. The rest sort themselves by recent use.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .listRowBackground(Color.clear)
                }
            }
            .macColors(connection.snapshot?.theme)
            .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    guard let project = renaming else { return }
                    connection.renameProject(project.id, to: newName)
                    if let i = projects.firstIndex(where: { $0.id == project.id }) {
                        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { projects[i].name = clean }
                    }
                }
            } message: {
                Text("Changes the name Tether shows. The folder on the Mac isn't renamed.")
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        connection.reorderProjects(projects.filter(\.pinned).map(\.id))
                        dismiss()
                    }
                }
            }
            .onAppear { projects = connection.snapshot?.projects ?? [] }
        }
    }
}
