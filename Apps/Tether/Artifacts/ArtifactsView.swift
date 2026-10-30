import AppKit
import SwiftUI
import TetherProtocol

/// Pages Claude published with its Artifact tool in the open conversation,
/// newest first. Click one to open it in the browser; the copy button takes
/// its link.
struct ArtifactsView: View {
    @Environment(\.theme) private var theme
    let items: [TranscriptItem]

    var body: some View {
        let artifacts = ArtifactList.published(in: items)
        if artifacts.isEmpty {
            ContentUnavailableView("No Artifacts Yet", systemImage: "doc.richtext",
                                   description: Text("Pages Claude publishes in this conversation, like dashboards and mockups, show up here."))
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(artifacts) { artifact in
                        ArtifactRow(artifact: artifact)
                    }
                }
                .padding(10)
            }
        }
    }
}

private struct ArtifactRow: View {
    @Environment(\.theme) private var theme
    let artifact: PublishedArtifact
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Button { NSWorkspace.shared.open(artifact.url) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.richtext").foregroundStyle(theme.claude)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artifact.title).font(.callout.weight(.medium)).foregroundStyle(theme.text).lineLimit(1)
                        Text(detail).font(.caption).foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in browser")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(artifact.url.absoluteString, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "link").foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Copy link")
        }
        .padding(10)
        .background(theme.elevated, in: RoundedRectangle(cornerRadius: 8))
    }

    private var detail: String {
        let version = artifact.versions > 1 ? "Version \(artifact.versions) · " : ""
        return version + artifact.at.formatted(.relative(presentation: .named))
    }
}
