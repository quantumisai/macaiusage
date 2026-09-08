import AppKit
import SwiftUI
import UsageCore

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { PreferencesView(model: delegate.model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel(demo: CommandLine.arguments.contains("--demo"))
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var preferencesWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model, openPreferences: { [weak self] in
            self?.showPreferences()
        }))
        model.onChange = { [weak self] in self?.updateStatusItem() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeFromSleep), name: NSWorkspace.didWakeNotification, object: nil)
        model.start()
        updateStatusItem()
        if CommandLine.arguments.contains("--settings") {
            showPreferences()
        } else if CommandLine.arguments.contains("--show") {
            togglePopover()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if model.snapshot == nil { symbol = model.errorMessage == nil ? "gauge.with.dots.needle.50percent" : "exclamationmark.circle" }
        else if model.isStale { symbol = "clock.arrow.circlepath" }
        else { symbol = "chart.donut" }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "QuotaBar")
        image?.isTemplate = true
        button.image = image
        let title = UsageFormatting.menuTitle(snapshot: model.snapshot, preferences: model.preferences, now: model.now, isStale: model.isStale)
        button.title = title.isEmpty ? "" : " \(title)"
        let low = (model.selectedWindow?.remainingPercent ?? 100) <= Double(model.preferences.warningThreshold)
        button.contentTintColor = low && !model.isStale ? .systemOrange : nil
        let tooltip = UsageFormatting.tooltip(snapshot: model.snapshot, preferences: model.preferences, now: model.now, isStale: model.isStale)
        button.toolTip = model.preferences.showHoverDetails ? tooltip : nil
        button.setAccessibilityLabel(tooltip)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.tick()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showPreferences() {
        popover.performClose(nil)
        model.syncLoginStatus()
        if preferencesWindow == nil {
            let controller = NSHostingController(rootView: PreferencesView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "QuotaBar Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            preferencesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func wokeFromSleep() {
        model.now = Date()
        model.refresh()
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        model.stop()
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit QuotaBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc private func openSettingsMenu() { showPreferences() }
}
