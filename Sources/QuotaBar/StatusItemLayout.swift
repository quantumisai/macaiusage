import AppKit
import UsageCore

/// Size to the current reading, with only two points of padding per side.
/// Zero and unavailable readings still have a nonzero, clickable allocation.
enum StatusItemLayout {
    static var font: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .medium) }
    static let imageSize = NSSize(width: 14, height: 14)

    static func title(codex: String, anthropic: String, showAnthropic: Bool) -> String {
        // Staleness remains explicit in hover details and the usage panel.
        let compact: (String) -> String = { $0.replacingOccurrences(of: " ·", with: "").replacingOccurrences(of: " / ", with: "/") }
        return showAnthropic ? "O\(compact(codex)) A\(compact(anthropic))" : compact(codex)
    }

    static func length(title: String, iconOnly: Bool) -> CGFloat {
        guard !iconOnly else { return NSStatusBar.system.thickness }
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        return max(NSStatusBar.system.thickness, ceil(textWidth) + 4)
    }
}
