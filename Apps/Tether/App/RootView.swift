import SwiftUI
import UniformTypeIdentifiers
import TetherProtocol

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let id = model.selectedProjectId,
               let project = model.projects.first(where: { $0.id == id }) {
                ProjectDetailPlaceholder(project: project)
            } else {
                ContentUnavailableView("No project selected",
                                       systemImage: "folder",
                                       description: Text("Add a project with ⇧⌘N."))
            }
        }
        .fileImporter(isPresented: $model.addProjectRequested,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await model.addProject(at: url) }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedProjectId) {
            Section("Projects") {
                ForEach(model.projects) { project in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(project.name)
                            Text(project.baseBranch)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(state: model.sessionStates[project.id] ?? .idle)
                    }
                    .tag(project.id)
                    .contextMenu {
                        Button("Remove Project", role: .destructive) {
                            Task { await model.removeProject(project.id) }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { model.addProjectRequested = true } label: {
                    Label("Add Project", systemImage: "plus")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}

/// Phase 0 placeholder. Phase 1 replaces this with the libghostty terminal tabs.
struct ProjectDetailPlaceholder: View {
    let project: Project

    var body: some View {
        VStack(spacing: 8) {
            Text(project.name).font(.title2)
            Text(project.path).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("Terminal lands in phase 1.").foregroundStyle(.tertiary)
        }
    }
}

/// Minimal static version. Phase 2 adds the working/done/needs-input animation.
struct StatusBadge: View {
    let state: SessionState

    var body: some View {
        switch state {
        case .idle, .detached:
            EmptyView()
        case .working:
            Image(systemName: "sparkles").foregroundStyle(.orange)
        case .needsInput:
            Circle().fill(.blue).frame(width: 8, height: 8)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Circle().fill(.red).frame(width: 8, height: 8)
        }
    }
}
