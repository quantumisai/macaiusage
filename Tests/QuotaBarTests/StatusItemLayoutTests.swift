import AppKit
import Testing
import UsageCore
@testable import QuotaBar

@MainActor
struct StatusItemLayoutTests {
    @Test func compactProviderLabels() {
        #expect(StatusItemLayout.title(codex: "13%", anthropic: "0%", showAnthropic: true) == "O13% A0%")
        #expect(StatusItemLayout.title(codex: "0% ·", anthropic: "100%", showAnthropic: false) == "0%")
        #expect(StatusItemLayout.length(display: .remaining, showAnthropic: true) < 110)
    }

    @Test func zeroFullMissingAndStaleReadingsFitTheSameAllocation() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for display in MenuDisplay.allCases where display != .iconOnly {
            for showAnthropic in [false, true] {
                var preferences = UsagePreferences()
                preferences.menuDisplay = display
                let length = StatusItemLayout.length(display: display, showAnthropic: showAnthropic)
                #expect(length > 0)
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
                            #expect(width + 12 <= length)
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
