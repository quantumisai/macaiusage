import AppKit
import UsageCore

/// Reserve the complete range of readings once per display configuration.
/// Live percentages, stale markers and error symbols must not resize the item:
/// macOS can move the entire item into overflow when its allocation changes.
enum StatusItemLayout {
    static var font: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .medium) }
    static let imageSize = NSSize(width: 14, height: 14)

    static func title(codex: String, anthropic: String, showAnthropic: Bool) -> String {
        // Staleness remains explicit in hover details and the usage panel.
        let compact: (String) -> String = { $0.replacingOccurrences(of: " ·", with: "").replacingOccurrences(of: " / ", with: "/") }
        return showAnthropic ? "O\(compact(codex)) A\(compact(anthropic))" : compact(codex)
    }

    static func length(display: MenuDisplay, showAnthropic: Bool) -> CGFloat {
        guard display != .iconOnly else { return NSStatusBar.system.thickness }
        let reading = display == .bothWindows ? "100%/100%" : "100%"
        let widestTitle = title(codex: reading, anthropic: reading, showAnthropic: showAnthropic)
        let textWidth = (widestTitle as NSString).size(withAttributes: [.font: font]).width
        // Percentages identify the app; reserve an icon only in icon-only mode.
        return ceil(textWidth) + 12
    }
}
