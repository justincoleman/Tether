import ActivityKit
import TetherProtocol

/// The Mac's push-to-start payloads name this type in `attributes-type`, and
/// encode `LiveActivityAttributes` / `LiveActivityContent` with their field
/// names, so the phone uses the protocol types directly. Compiled into the
/// app and the widget extension.
extension LiveActivityAttributes: @retroactive ActivityAttributes {
    public typealias ContentState = LiveActivityContent
}
