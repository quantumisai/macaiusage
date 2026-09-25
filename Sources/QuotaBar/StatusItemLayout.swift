import AppKit
import UsageCore

/// Reserve the complete range of readings once per display configuration.
/// Live percentages, stale markers and error symbols must not resize the item:
/// macOS can move the entire item into overflow when its allocation changes.
enum StatusItemLayout {
    static var font: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .medium) }
    static let imageSize = NSSize(width: 14, height: 14)

    static func length(display: MenuDisplay, showAnthropic: Bool) -> CGFloat {
        guard display != .iconOnly else { return NSStatusBar.system.thickness }
        let reading = display == .bothWindows ? "100% / 100% ·" : "100% ·"
        let widestTitle = showAnthropic ? " O \(reading)  A \(reading)" : " \(reading)"
        let textWidth = (widestTitle as NSString).size(withAttributes: [.font: font]).width
        // Fixed icon, image/title spacing, and both button insets.
        return ceil(textWidth) + imageSize.width + 20
    }
}
