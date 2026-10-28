import SwiftUI
import TetherCore
import TetherProtocol

/// Edits a project's shortcuts: commands like `npm run dev` that get a
/// button in the top bar and run in their own tab.
struct ShortcutsEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var actions: [QuickAction] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcuts for \(project.name)").font(.headline)
            Text("Each shortcut runs its command in a new tab, in the folder of the tab you're on. The first three also get a button in the top bar. Click a running one again to jump to its tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if actions.isEmpty {
                Text("No shortcuts yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                HStack {
                    Text("Name (optional)").frame(width: 140, alignment: .leading)
                    Text("Command")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach($actions) { $action in
                    HStack {
                        TextField("Dev server", text: $action.name)
                            .frame(width: 140)
                        TextField("npm run dev", text: $action.command)
                            .font(.body.monospaced())
                        Button {
                            actions.removeAll { $0.id == action.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            }
            Button {
                actions.append(QuickAction(projectId: project.id, name: "", command: ""))
            } label: {
                Label("Add Shortcut", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let edited = actions
                    Task {
                        await model.setQuickActions(edited, for: project.id)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 520)
        .onAppear { actions = model.quickActions(for: project.id) }
    }
}
