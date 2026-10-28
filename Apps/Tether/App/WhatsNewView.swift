import AppKit
import SwiftUI
import TetherCore

/// The What's New window: every release since the last one you read.
struct WhatsNewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let store = model.releases
        let unseenIds = Set(store.unseen.map(\.id))
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(store)
                    ForEach(store.displayed) { note in
                        ReleaseSection(note: note, isNew: unseenIds.contains(note.id))
                        if note.id != store.displayed.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    store.markSeen()
                    dismissWindow(id: "whats-new")
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 440, idealHeight: 680)
        .background(theme.window)
        .onDisappear { store.markSeen() }
    }

    private func header(_ store: ReleaseNotesStore) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tether is up to date").font(.title.weight(.bold))
                Text(subtitle(store))
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func subtitle(_ store: ReleaseNotesStore) -> String {
        let n = store.unseen.count
        switch n {
        case 0: return "You're on \(store.current). Here's what's in this version."
        case 1: return "You're on \(store.current). Here's what's new."
        default: return "You're on \(store.current). Here's what changed in the \(n) versions since you last opened it."
        }
    }
}

private struct ReleaseSection: View {
    @Environment(\.theme) private var theme
    let note: ReleaseNote
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tether \(note.version)").font(.title2.weight(.bold))
                if isNew {
                    Text("New")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(theme.elevated, in: Capsule())
                }
                Spacer()
                Text(Self.display(note.date)).font(.callout).foregroundStyle(theme.secondaryText)
            }
            Text(note.summary)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(note.highlights.enumerated()), id: \.offset) { _, highlight in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").foregroundStyle(theme.secondaryText)
                        (Text(highlight.title + " ").bold() + Text(highlight.body))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func display(_ iso: String) -> String {
        parser.date(from: iso).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? iso
    }
}

/// The small card at the bottom of the sidebar that announces a new release.
struct WhatsNewToast: View {
    @Environment(\.theme) private var theme
    let version: String
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.claude)
            VStack(alignment: .leading, spacing: 1) {
                Text("What's new").font(.callout.weight(.semibold))
                Text("Tether \(version)").font(.caption).foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.border, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("What's new in Tether \(version)")
    }
}
