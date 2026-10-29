import Foundation
import GhosttyTerminal
import Observation
import TetherCore
import TetherProtocol

/// One terminal tab: a libghostty surface bound to a persisted `PaneDescriptor`.
@MainActor
@Observable
final class TerminalPane: Identifiable {
    let descriptor: PaneDescriptor
    let terminal: TerminalViewState
    private(set) var title: String
    private(set) var hasExited = false
    var onExit: ((PaneID) -> Void)?

    nonisolated var id: PaneID { descriptor.id }

    init(descriptor: PaneDescriptor, launch: TerminalLaunch, controller: TerminalController) {
        self.descriptor = descriptor
        self.title = descriptor.title
        self.terminal = TerminalViewState(controller: controller)
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: launch.workingDirectory,
            envVars: launch.environment,
            command: launch.command,
            waitAfterCommand: true,
            resizeThrottleMilliseconds: 16)
        terminal.onClose = { [weak self] _ in
            guard let self else { return }
            self.hasExited = true
            self.onExit?(self.id)
        }
    }

    /// Pastes a prompt and presses Enter. Paste and Enter are separate paths on
    /// purpose: a pasted `\r` is a character under bracketed paste, not submit.
    @discardableResult
    func send(prompt: String) -> Bool {
        let text = TerminalLaunch.promptText(prompt)
        guard terminal.paste(text: text) else { return false }
        return terminal.sendKey(.enter)
    }

    /// Shift-Tab, which moves Claude Code to its next permission mode.
    @discardableResult
    func cycleMode() -> Bool { terminal.sendKey(.tab, modifiers: .shift) }

    /// Return, which takes the highlighted answer of a dialog.
    @discardableResult
    func confirm() -> Bool { terminal.sendKey(.enter) }

    /// Esc, which stops Claude's current turn like pressing it in the terminal.
    @discardableResult
    func interrupt() -> Bool { terminal.sendKey(.escape) }

    var isClaude: Bool {
        if case .claude = descriptor.kind { return true }
        return false
    }

    func focus() { terminal.requestFocus() }

    func setVisible(_ visible: Bool) { terminal.isSurfaceVisible = visible }
}
