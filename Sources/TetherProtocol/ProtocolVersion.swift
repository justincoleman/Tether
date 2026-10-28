/// Bumped whenever a wire message changes shape. Both sides send it in `Hello`;
/// the older side shows an "Update needed" banner on mismatch.
public enum ProtocolVersion {
    public static let current: Int = 6 // 2: MirrorEvent.notice, 3: Session.attention, 4: companion v1, 5: startSession/startResult, 6: SessionSummary.preview
}
