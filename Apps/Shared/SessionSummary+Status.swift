import TetherProtocol

/// One line on what a tab needs, shared by the iPhone and the Remote Macs window.
extension SessionSummary {
    var statusNote: String? {
        if state == .needsInput {
            switch attention {
            case .permission: return "Needs permission"
            case .question: return "Asked you a question"
            case .dialog: return "Waiting on a prompt on the Mac"
            case nil: return "Needs your input"
            }
        }
        if queued > 0 { return "\(queued) queued" }
        switch state {
        case .working: return "Working"
        case .detached: return "Ended"
        default: return nil
        }
    }
}
