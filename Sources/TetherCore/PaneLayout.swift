import Foundation
import TetherProtocol

/// Which way a split divides the terminal card.
public enum SplitAxis: String, Codable, Hashable, Sendable {
    /// Side by side, divider running top to bottom.
    case horizontal
    /// One above the other.
    case vertical

    public var toggled: SplitAxis { self == .horizontal ? .vertical : .horizontal }
}

/// Two tabs of one project shown together. Selecting either tab shows both,
/// with the selected one focused. A pane is in at most one split.
public struct PaneSplit: Codable, Hashable, Sendable {
    public var projectId: ProjectID
    /// Left or top.
    public var first: PaneID
    /// Right or bottom.
    public var second: PaneID
    public var axis: SplitAxis
    /// Share of the card the first pane gets.
    public var fraction: Double

    public static let fractionRange: ClosedRange<Double> = 0.2...0.8

    public init(projectId: ProjectID, first: PaneID, second: PaneID,
                axis: SplitAxis = .horizontal, fraction: Double = 0.5) {
        self.projectId = projectId
        self.first = first
        self.second = second
        self.axis = axis
        self.fraction = Self.clamp(fraction)
    }

    public static func clamp(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0.5 }
        return min(max(fraction, fractionRange.lowerBound), fractionRange.upperBound)
    }

    public func contains(_ pane: PaneID) -> Bool { first == pane || second == pane }

    /// The other half, or nil when `pane` isn't in this split.
    public func partner(of pane: PaneID) -> PaneID? {
        if pane == first { return second }
        if pane == second { return first }
        return nil
    }
}

public enum PaneLayout {
    /// The split holding `pane`, if any.
    public static func split(containing pane: PaneID?, in splits: [PaneSplit]) -> PaneSplit? {
        guard let pane else { return nil }
        return splits.first { $0.contains(pane) }
    }

    /// Adds `split`, dropping any split that already held either of its panes,
    /// so every pane stays in at most one. A pane can't be split with itself.
    public static func adding(_ split: PaneSplit, to splits: [PaneSplit]) -> [PaneSplit] {
        guard split.first != split.second else { return splits }
        return splits.filter { !$0.contains(split.first) && !$0.contains(split.second) } + [split]
    }

    /// Drops splits that refer to a pane not in `existing`.
    public static func pruning(_ splits: [PaneSplit], existing: Set<PaneID>) -> [PaneSplit] {
        splits.filter { existing.contains($0.first) && existing.contains($0.second) }
    }

    /// `ids` with `pane` taken out and put where `target` was, the way a
    /// dragged tab lands: dropped on a tab to its right, it goes after that
    /// tab; dropped on a tab to its left, before it.
    public static func moving(_ pane: PaneID, onto target: PaneID, in ids: [PaneID]) -> [PaneID] {
        guard pane != target,
              let from = ids.firstIndex(of: pane),
              let to = ids.firstIndex(of: target) else { return ids }
        var result = ids
        result.remove(at: from)
        result.insert(pane, at: to)
        return result
    }

    /// `ids` with `pane` placed right after `anchor`.
    public static func placing(_ pane: PaneID, after anchor: PaneID, in ids: [PaneID]) -> [PaneID] {
        guard pane != anchor, ids.contains(pane) else { return ids }
        var result = ids.filter { $0 != pane }
        guard let at = result.firstIndex(of: anchor) else { return ids }
        result.insert(pane, at: at + 1)
        return result
    }

    /// Rewrites one project's order inside a list that interleaves several
    /// projects: the project's slots stay where they are and take its panes
    /// in `order`. Ids in `order` that aren't in `all` are ignored, and any of
    /// the project's ids missing from `order` keep their relative order after it.
    public static func reordering<T>(_ all: [T], id: (T) -> PaneID, inProject: (T) -> Bool,
                                     to order: [PaneID]) -> [T] {
        let slots = all.indices.filter { inProject(all[$0]) }
        let members = slots.map { all[$0] }
        var rank: [PaneID: Int] = [:]
        for (i, pane) in order.enumerated() where rank[pane] == nil { rank[pane] = i }
        let sorted = members.enumerated().sorted { a, b in
            let ra = rank[id(a.element)] ?? (order.count + a.offset)
            let rb = rank[id(b.element)] ?? (order.count + b.offset)
            return ra < rb
        }.map(\.element)
        var result = all
        for (slot, member) in zip(slots, sorted) { result[slot] = member }
        return result
    }
}
