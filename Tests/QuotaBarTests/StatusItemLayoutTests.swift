import AppKit
import Testing
import UsageCore
@testable import QuotaBar

@MainActor
struct StatusItemLayoutTests {
    @Test func compactProviderLabels() {
        #expect(StatusItemLayout.title(codex: "13%", anthropic: "0%", showAnthropic: true) == "O13% A0%")
        #expect(StatusItemLayout.title(codex: "0% ·", anthropic: "100%", showAnthropic: false) == "0%")
        let shortTitle = StatusItemLayout.title(codex: "0%", anthropic: "0%", showAnthropic: true)
        let fullTitle = StatusItemLayout.title(codex: "100%", anthropic: "100%", showAnthropic: true)
        #expect(StatusItemLayout.length(title: shortTitle, iconOnly: false) < StatusItemLayout.length(title: fullTitle, iconOnly: false))
    }

    @Test func iconAndEmptyReadingsKeepASquareClickTarget() {
        #expect(StatusItemLayout.length(title: "", iconOnly: true) == NSStatusBar.system.thickness)
        #expect(StatusItemLayout.length(title: "", iconOnly: false) == NSStatusBar.system.thickness)
    }

    @Test func zeroFullMissingAndStaleReadingsStayClickableAndFit() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for display in MenuDisplay.allCases where display != .iconOnly {
            for showAnthropic in [false, true] {
                var preferences = UsagePreferences()
                preferences.menuDisplay = display
                for used in [0.0, 1, 50, 99, 100] {
                    for stale in [false, true] {
                        let snapshot = UsageSnapshot(planName: nil, windows: [
                            UsageWindow(id: "s", title: "Session", usedPercent: used, durationMinutes: 300, resetsAt: now.addingTimeInterval(60)),
                            UsageWindow(id: "w", title: "Weekly", usedPercent: used, durationMinutes: 10080, resetsAt: now.addingTimeInterval(60)),
                        ], fetchedAt: now)
                        for value in [snapshot, nil] {
                            let reading = UsageFormatting.menuTitle(snapshot: value, preferences: preferences, now: now, isStale: stale)
                            let title = StatusItemLayout.title(codex: reading, anthropic: reading, showAnthropic: showAnthropic)
                            let width = (title as NSString).size(withAttributes: [.font: StatusItemLayout.font]).width
                            let length = StatusItemLayout.length(title: title, iconOnly: false)
                            #expect(length >= NSStatusBar.system.thickness)
                            #expect(width + 4 <= length)
                            #expect(length == max(NSStatusBar.system.thickness, ceil(width) + 4))
                            if used == 100, !stale, value != nil, display == .remaining {
                                #expect(reading == "0%")
                            }
                        }
                    }
                }
            }
        }
    }
}
