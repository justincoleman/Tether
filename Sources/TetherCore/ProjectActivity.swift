import Foundation
import TetherProtocol

/// When a project was last used, and whether the user pinned it or moved it
/// to Inactive. Drives the sidebar's Pinned, Active and Inactive sections.
public struct ProjectActivity: Codable, Sendable, Equatable {
    /// The latest prompt, new tab, Claude turn, or transcript write from
    /// Claude Code outside Tether.
    public var lastUsed: Date?
    /// Kept at the top of Active, in the user's order (`Project.order`).
    public var pinned: Bool
    /// Set by Move to Inactive. Any use after it clears it.
    public var movedInactiveAt: Date?

    public static let defaultInactiveAfterDays = 3

    public init(lastUsed: Date? = nil, pinned: Bool = false, movedInactiveAt: Date? = nil) {
        self.lastUsed = lastUsed
        self.pinned = pinned
        self.movedInactiveAt = movedInactiveAt
    }

    enum CodingKeys: String, CodingKey { case lastUsed, pinned, movedInactiveAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        movedInactiveAt = try c.decodeIfPresent(Date.self, forKey: .movedInactiveAt)
    }

    /// Records a use. Returns whether it's worth writing to disk: the first
    /// use, one that brings the project back from Inactive, or one a minute
    /// or more after the last, so a busy session doesn't write on every hook.
    @discardableResult
    public mutating func touch(at date: Date) -> Bool {
        var changed = false
        if let moved = movedInactiveAt, date > moved {
            movedInactiveAt = nil
            changed = true
        }
        guard let last = lastUsed else {
            lastUsed = date
            return true
        }
        guard date > last else { return changed }
        lastUsed = date
        return changed || date.timeIntervalSince(last) >= 60
    }

    public mutating func moveToInactive(at date: Date) {
        pinned = false
        movedInactiveAt = date
    }

    public mutating func makeActive(at date: Date) {
        movedInactiveAt = nil
        lastUsed = max(lastUsed ?? date, date)
    }

    public func isActive(now: Date, inactiveAfterDays: Int) -> Bool {
        if movedInactiveAt != nil { return false }
        if pinned { return true }
        guard let lastUsed else { return false }
        return now.timeIntervalSince(lastUsed) < Double(max(inactiveAfterDays, 1)) * 86_400
    }
}

/// The sidebar's three groups, in display order.
public struct ProjectSections: Sendable, Equatable {
    public var pinned: [Project]
    public var active: [Project]
    public var inactive: [Project]

    /// Pinned in the user's order, then the rest of Active most recent first,
    /// then Inactive most recent first (never-used last, by name).
    public init(projects: [Project], activity: [ProjectID: ProjectActivity],
                now: Date, inactiveAfterDays: Int) {
        var pinned: [Project] = [], active: [Project] = [], inactive: [Project] = []
        for project in projects {
            let a = activity[project.id] ?? ProjectActivity()
            if !a.isActive(now: now, inactiveAfterDays: inactiveAfterDays) {
                inactive.append(project)
            } else if a.pinned {
                pinned.append(project)
            } else {
                active.append(project)
            }
        }
        let last = { (p: Project) in activity[p.id]?.lastUsed ?? .distantPast }
        self.pinned = pinned.sorted { $0.order < $1.order }
        self.active = active.sorted { last($0) != last($1) ? last($0) > last($1) : $0.order < $1.order }
        self.inactive = inactive.sorted {
            last($0) != last($1) ? last($0) > last($1)
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Everything in display order.
    public var all: [Project] { pinned + active + inactive }
}
