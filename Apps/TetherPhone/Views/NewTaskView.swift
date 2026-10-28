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
    @State private var error: String?
    @State private var starting = false

    private var online: [MacConnection] {
        store.connections.filter { $0.status == .online && $0.snapshot != nil }
    }

    private var connection: MacConnection? {
        online.first { $0.id == macId } ?? online.first
    }

    private var projects: [ProjectSummary] { connection?.snapshot?.projects ?? [] }

    private var canStart: Bool {
        !starting && connection != nil && projectId != nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!onBranch || !branch.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
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
            switch await connection.startSession(projectId: projectId, branch: branchName, prompt: prompt) {
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

/// Drag to reorder a Mac's projects; the Mac's sidebar follows.
struct ReorderProjectsView: View {
    let connection: MacConnection
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [ProjectSummary] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(projects) { Text($0.name) }
                    .onMove { projects.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Projects on \(connection.mac.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        connection.reorderProjects(projects.map(\.id))
                        dismiss()
                    }
                }
            }
            .onAppear { projects = connection.snapshot?.projects ?? [] }
        }
    }
}
