/// Bumped whenever a wire message changes shape. Both sides send it in `Hello`;
/// the older side shows an "Update needed" banner on mismatch.
public enum ProtocolVersion {
    public static let current: Int = 3 // 2: MirrorEvent.notice, 3: Session.attention
}
