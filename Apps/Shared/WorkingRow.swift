import SwiftUI

/// "Working" with a Stop button, at the end of a chat while Claude is mid-turn.
struct WorkingRow: View {
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Working").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill").font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
