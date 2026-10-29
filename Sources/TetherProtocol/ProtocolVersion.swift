/// Bumped whenever a wire message changes shape. Both sides send it in `Hello`;
/// the older side shows an "Update needed" banner on mismatch.
public enum ProtocolVersion {
    public static let current: Int = 14 // 2: MirrorEvent.notice, 3: Session.attention, 4: companion v1, 5: startSession/startResult, 6: SessionSummary.preview, 7: permission modes, 8: renameProject, 9: push registration, 10: closeSession, 11: projectIcons, 12: status line (SessionSummary.status, Snapshot.limits, setModel), 13: SessionStatus.contextWindow, 14: changes, diffs and images
}
