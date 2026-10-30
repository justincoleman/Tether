import AppKit
import SwiftUI

/// Keeps terminal hosts attached at valid dimensions even when another screen
/// covers them. Removing a host destroys its libghostty surface and process.
struct PersistentTerminalStack<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let selection: Item.ID?
    @ViewBuilder var content: (Item, Bool) -> Content

    var body: some View {
        ZStack {
            ForEach(items) { item in
                let active = item.id == selection
                content(item, active)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .disabled(!active)
                    .accessibilityHidden(!active)
            }
        }
    }
}

/// Hiding an attached AppKit terminal does not automatically release keyboard
/// focus. Only clear focus owned by this host; never steal it from a new pane.
@MainActor
enum TerminalFocus {
    static func resignIfOwned(by view: NSView?) {
        guard let view, let window = view.window,
              let responder = window.firstResponder as? NSView,
              responder === view || responder.isDescendant(of: view) else { return }
        window.makeFirstResponder(nil)
    }
}
