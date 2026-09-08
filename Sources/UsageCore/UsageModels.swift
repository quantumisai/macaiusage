import Foundation

public struct UsageWindow: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init(id: String, title: String, usedPercent: Double, durationMinutes: Int?, resetsAt: Date?) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent.isFinite ? min(100, max(0, usedPercent)) : 0
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double { 100 - usedPercent }
    public func awaitsResetConfirmation(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public let planName: String?
    public let windows: [UsageWindow]
    public let fetchedAt: Date

    public init(planName: String?, windows: [UsageWindow], fetchedAt: Date) {
        self.planName = planName
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

public enum TrackedWindow: String, CaseIterable, Codable, Sendable {
    case session, weekly, mostLimited

    public var label: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        case .mostLimited: "Lowest remaining"
        }
    }

    public func select(from snapshot: UsageSnapshot?) -> UsageWindow? {
        guard let snapshot else { return nil }
        switch self {
        case .session: return snapshot.windows.first { ($0.durationMinutes ?? 0) > 0 && ($0.durationMinutes ?? 0) < 1_440 }
        case .weekly: return snapshot.windows.first { ($0.durationMinutes ?? 0) >= 10_080 }
        case .mostLimited: return snapshot.windows.min { $0.remainingPercent < $1.remainingPercent }
        }
    }
}

public enum MenuDisplay: String, CaseIterable, Codable, Sendable {
    case remaining, used, bothWindows, iconOnly
    public var label: String {
        switch self {
        case .remaining: "Percent remaining"
        case .used: "Percent used"
        case .bothWindows: "Session + weekly remaining"
        case .iconOnly: "Icon only"
        }
    }
}

public enum ResetDisplay: String, CaseIterable, Codable, Sendable {
    case countdown, clock, both
    public var label: String {
        switch self {
        case .countdown: "Countdown"
        case .clock: "Date & time"
        case .both: "Countdown + date & time"
        }
    }
}

public struct UsagePreferences: Codable, Sendable, Equatable {
    public var trackedWindow: TrackedWindow = .mostLimited
    public var menuDisplay: MenuDisplay = .remaining
    public var resetDisplay: ResetDisplay = .both
    public var refreshMinutes: Int = 2
    public var warningThreshold: Int = 20
    public var showHoverDetails: Bool = true
    public var executablePath: String = ""

    public init() {}

    public mutating func normalize() {
        if ![1, 2, 5, 15].contains(refreshMinutes) { refreshMinutes = 2 }
        warningThreshold = min(50, max(0, warningThreshold))
        executablePath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum UsageFormatting {
    public static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    public static func countdown(to date: Date?, now: Date) -> String {
        guard let date else { return "Reset time unavailable" }
        guard date > now else { return "Reset due · awaiting update" }
        let minutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        let rest = minutes % 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(rest)m" }
        return "Resets in \(rest)m"
    }

    public static func reset(_ date: Date?, style: ResetDisplay, now: Date) -> String {
        guard let date else { return "Reset time unavailable" }
        let absolute = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute().timeZone(.specificName(.short)))
        switch style {
        case .countdown: return countdown(to: date, now: now)
        case .clock: return "Resets \(absolute)"
        case .both: return "\(countdown(to: date, now: now))\n\(absolute)"
        }
    }

    public static func menuTitle(snapshot: UsageSnapshot?, preferences: UsagePreferences, now: Date, isStale: Bool) -> String {
        guard preferences.menuDisplay != .iconOnly else { return "" }
        guard let snapshot else { return "—" }
        let suffix = isStale ? " ·" : ""
        if preferences.menuDisplay == .bothWindows {
            let primary = TrackedWindow.session.select(from: snapshot)
            let secondary = TrackedWindow.weekly.select(from: snapshot)
            func value(_ window: UsageWindow?) -> String {
                guard let window, !window.awaitsResetConfirmation(at: now) else { return "—" }
                return percent(window.remainingPercent)
            }
            return "\(value(primary)) / \(value(secondary))\(suffix)"
        }
        guard let selected = preferences.trackedWindow.select(from: snapshot), !selected.awaitsResetConfirmation(at: now) else { return "—" }
        let value = preferences.menuDisplay == .used ? selected.usedPercent : selected.remainingPercent
        return "\(percent(value))\(suffix)"
    }

    public static func tooltip(snapshot: UsageSnapshot?, preferences: UsagePreferences, now: Date, isStale: Bool) -> String {
        guard let snapshot else { return "QuotaBar · Connect your ChatGPT account to see Codex usage" }
        let header = "QuotaBar · Codex\(snapshot.planName.map { " · \($0.capitalized)" } ?? "")"
        let rows = snapshot.windows.map { window in
            let amount = window.awaitsResetConfirmation(at: now) ? "Awaiting updated usage" : "\(percent(window.remainingPercent)) remaining"
            return "\(window.title): \(amount)\n\(reset(window.resetsAt, style: preferences.resetDisplay, now: now))"
        }
        let freshness = isStale ? "\nLast known usage · update needed" : ""
        return ([header] + rows).joined(separator: "\n\n") + freshness
    }
}
