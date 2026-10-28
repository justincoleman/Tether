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
                TerminalTabsView(project: project)
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
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 8)
                            .fill((model.sessionStates[project.id] ?? .idle).tint ?? .clear)
                            .padding(.horizontal, 4)
                    )
                    .contextMenu {
                        Button("Remove Project", role: .destructive) {
                            Task { await model.removeProject(project.id) }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.hookStatusMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
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
