import Foundation
import Testing
@testable import UsageCore

struct UsageModelsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        id: String = "primary",
        used: Double = 35,
        minutes: Int? = 300,
        resetAfter: TimeInterval? = 3_600
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            title: "Test window",
            usedPercent: used,
            durationMinutes: minutes,
            resetsAt: resetAfter.map { now.addingTimeInterval($0) }
        )
    }

    private func snapshot(_ windows: [UsageWindow]) -> UsageSnapshot {
        UsageSnapshot(planName: "pro", windows: windows, fetchedAt: now)
    }

    @Test(arguments: [(-10.0, 100.0), (0, 100), (35.5, 64.5), (100, 0), (120, 0)])
    func remainingUsageStaysWithinPercentageBounds(values: (Double, Double)) {
        #expect(window(used: values.0).remainingPercent == values.1)
    }

    @Test(arguments: [(0.0, "0%"), (25.4, "25%"), (25.5, "26%"), (100, "100%")])
    func menuPercentRoundsToNearestWholeNumber(values: (Double, String)) {
        #expect(UsageFormatting.percent(values.0) == values.1)
    }

    @Test(arguments: [
        (-1.0, "Reset due · awaiting update"),
        (0, "Reset due · awaiting update"),
        (0.1, "Resets in 1m"),
        (60, "Resets in 1m"),
        (60.1, "Resets in 2m"),
        (3_600, "Resets in 1h 0m"),
        (3_601, "Resets in 1h 1m"),
        (86_400, "Resets in 1d 0h"),
        (176_400, "Resets in 2d 1h")
    ])
    func resetCountdownHandlesBoundaries(values: (Double, String)) {
        #expect(UsageFormatting.countdown(to: now.addingTimeInterval(values.0), now: now) == values.1)
    }

    @Test
    func absentResetIsUnknown() {
        #expect(UsageFormatting.countdown(to: nil, now: now) == "Reset time unavailable")
        #expect(!window(resetAfter: nil).awaitsResetConfirmation(at: now))
    }

    @Test
    func weeklyWindowCanOccupyThePrimaryAPISlot() {
        let weekly = window(id: "primary", used: 22, minutes: 10_080)
        let data = snapshot([weekly])

        #expect(TrackedWindow.weekly.select(from: data) == weekly)
        #expect(TrackedWindow.session.select(from: data) == nil)
        #expect(TrackedWindow.mostLimited.select(from: data) == weekly)

        var preferences = UsagePreferences()
        preferences.menuDisplay = .bothWindows
        #expect(UsageFormatting.menuTitle(snapshot: data, preferences: preferences, now: now, isStale: false) == "— / 78%")
    }

    @Test
    func unknownWindowDurationDoesNotInventSessionOrWeeklyQuota() {
        let unknown = window(minutes: nil)
        let data = snapshot([unknown])
        #expect(TrackedWindow.session.select(from: data) == nil)
        #expect(TrackedWindow.weekly.select(from: data) == nil)
        #expect(TrackedWindow.mostLimited.select(from: data) == unknown)
    }

    @Test
    func mostLimitedSelectionUsesRemainingQuota() {
        let session = window(used: 42)
        let weekly = window(id: "secondary", used: 81, minutes: 10_080)
        #expect(TrackedWindow.mostLimited.select(from: snapshot([session, weekly])) == weekly)
        #expect(TrackedWindow.mostLimited.select(from: snapshot([])) == nil)
        #expect(TrackedWindow.mostLimited.select(from: nil) == nil)
    }

    @Test
    func menuSupportsRemainingUsedAndStaleValues() {
        let data = snapshot([window(used: 35)])
        var preferences = UsagePreferences()
        #expect(UsageFormatting.menuTitle(snapshot: data, preferences: preferences, now: now, isStale: false) == "65%")
        #expect(UsageFormatting.menuTitle(snapshot: data, preferences: preferences, now: now, isStale: true) == "65% ·")

        preferences.menuDisplay = .used
        #expect(UsageFormatting.menuTitle(snapshot: data, preferences: preferences, now: now, isStale: false) == "35%")
    }

    @Test(arguments: [-1.0, 0])
    func elapsedResetHidesOldMenuPercentageUntilServerConfirmsNewUsage(resetAfter: Double) {
        let data = snapshot([window(used: 100, resetAfter: resetAfter)])
        let preferences = UsagePreferences()
        #expect(UsageFormatting.menuTitle(snapshot: data, preferences: preferences, now: now, isStale: false) == "—")
        #expect(UsageFormatting.menuTitle(snapshot: data, preferences: preferences, now: now, isStale: true) == "—")
    }

    @Test
    func twoWindowMenuPreservesValidQuotaWhenOtherResetHasElapsed() {
        let data = snapshot([
            window(used: 15),
            window(id: "secondary", used: 100, minutes: 10_080, resetAfter: -1)
        ])
        var preferences = UsagePreferences()
        preferences.menuDisplay = .bothWindows
        #expect(UsageFormatting.menuTitle(snapshot: data, preferences: preferences, now: now, isStale: false) == "85% / —")
    }

    @Test
    func missingUsageNeverDisplaysFullQuota() {
        var preferences = UsagePreferences()
        #expect(UsageFormatting.menuTitle(snapshot: nil, preferences: preferences, now: now, isStale: false) == "—")
        #expect(UsageFormatting.menuTitle(snapshot: snapshot([]), preferences: preferences, now: now, isStale: false) == "—")
        preferences.menuDisplay = .iconOnly
        #expect(UsageFormatting.menuTitle(snapshot: nil, preferences: preferences, now: now, isStale: false).isEmpty)
    }

    @Test
    func staleTooltipExplainsThatValuesNeedAnUpdate() {
        let preferences = UsagePreferences()
        let tooltip = UsageFormatting.tooltip(snapshot: snapshot([window()]), preferences: preferences, now: now, isStale: true)
        #expect(tooltip.contains("65% remaining"))
        #expect(tooltip.contains("Last known usage · update needed"))
    }

    @Test
    func elapsedResetDoesNotPresentOldPercentageAsCurrentInTooltip() {
        let preferences = UsagePreferences()
        let tooltip = UsageFormatting.tooltip(snapshot: snapshot([window(used: 100, resetAfter: 0)]), preferences: preferences, now: now, isStale: false)
        #expect(tooltip.contains("Awaiting updated usage"))
        #expect(tooltip.contains("Reset due · awaiting update"))
        #expect(!tooltip.contains("0% remaining"))
    }

    @Test(arguments: [(-1, 0), (0, 0), (20, 20), (50, 50), (200, 50)])
    func preferenceWarningThresholdIsClamped(values: (Int, Int)) {
        var preferences = UsagePreferences()
        preferences.warningThreshold = values.0
        preferences.normalize()
        #expect(preferences.warningThreshold == values.1)
    }

    @Test(arguments: [1, 2, 5, 15])
    func supportedRefreshIntervalsSurviveNormalization(minutes: Int) {
        var preferences = UsagePreferences()
        preferences.refreshMinutes = minutes
        preferences.normalize()
        #expect(preferences.refreshMinutes == minutes)
    }

    @Test
    func invalidPreferencesRecoverToSafeValuesAndTrimTheExecutablePath() {
        var preferences = UsagePreferences()
        preferences.refreshMinutes = -500
        preferences.executablePath = " \n/usr/local/bin/codex \n"
        preferences.normalize()
        #expect(preferences.refreshMinutes == 2)
        #expect(preferences.executablePath == "/usr/local/bin/codex")
    }
}
