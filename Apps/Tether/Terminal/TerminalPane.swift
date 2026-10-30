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
    var sendHandler: ((String) -> Bool)?
    var interruptHandler: (() -> Bool)?
    var usesNativeCodexChat: Bool { descriptor.kind.agent == .codex && descriptor.codexChat == true }
    @ObservationIgnored private var focusTask: Task<Void, Never>?

    nonisolated var id: PaneID { descriptor.id }

    init(descriptor: PaneDescriptor, launch: TerminalLaunch, controller: TerminalController) {
        self.descriptor = descriptor
        self.title = descriptor.title
        self.terminal = TerminalViewState(controller: controller)
        if !usesNativeCodexChat { terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: launch.workingDirectory,
            envVars: launch.environment,
            command: launch.command,
            waitAfterCommand: true,
            resizeThrottleMilliseconds: 16) }
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
        if let sendHandler { return sendHandler(prompt) }
        let text = TerminalLaunch.promptText(prompt)
        guard terminal.paste(text: text) else { return false }
        return terminal.sendKey(.enter)
    }

    /// Shift-Tab, which moves Claude Code to its next permission mode.
    @discardableResult
    func cycleMode() -> Bool { terminal.sendKey(.tab, modifiers: .shift) }

    /// "Yes, I trust this folder" in Claude's trust dialog. It is the second
    /// option, below the highlighted "No, exit", so a bare Return would quit.
    @discardableResult
    func trustFolder() -> Bool { terminal.sendKey(.arrowDown) && terminal.sendKey(.enter) }

    /// Esc, which stops Claude's current turn like pressing it in the terminal.
    @discardableResult
    func interrupt() -> Bool { interruptHandler?() ?? terminal.sendKey(.escape) }

    /// Claude Code's faint suggested prompt, read off the screen. Only ask
    /// when nothing can have been typed into the terminal (see PromptSuggestion).
    func promptSuggestion() -> String? {
        guard isClaude else { return nil }
        return TerminalScreen.bottomText(of: terminal).flatMap(PromptSuggestion.extract(viewport:))
    }

    var isClaude: Bool {
        if case .claude = descriptor.kind { return true }
        return false
    }

    /// The coding agent in this tab, or nil for shells, ssh and quick actions.
    var agent: AgentKind? { descriptor.kind.agent }

    /// A Claude or Codex tab: hooks drive its status, approvals and queue.
    /// Chat, model and mode controls stay Claude-only (`isClaude`).
    var isAgent: Bool { agent != nil }

    func focus() {
        focusTask?.cancel()
        // Ghostty's requestFocus keeps an unconditional deferred request. Own
        // this hop instead so navigation can cancel it before a hidden pane
        // takes first responder. Briefly allow a newly mounted view to attach.
        focusTask = Task { [weak self] in
            await Task.yield()
            for _ in 0..<5 {
                guard let self, !Task.isCancelled, self.terminal.isSurfaceVisible else { return }
                if self.terminal.attachedPlatformView?.acquireProgrammaticFocus() == true { return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    func setVisible(_ visible: Bool) {
        terminal.isSurfaceVisible = visible
        if !visible {
            focusTask?.cancel()
            focusTask = nil
            TerminalFocus.resignIfOwned(by: terminal.attachedPlatformView)
        }
    }
}
