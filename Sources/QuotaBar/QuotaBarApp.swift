import AppKit
import SwiftUI
import UsageCore

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { PreferencesView(model: delegate.model) }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Show Usage", action: delegate.showUsage)
                        .keyboardShortcut("u", modifiers: .command)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel(demo: CommandLine.arguments.contains("--demo"))
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var preferencesWindow: NSWindow?
    private var usageWindow: NSWindow?
    private var instanceLock: SingleInstanceLock?
    private let reopenNotification = Notification.Name("com.senna.quotabar.showUsage")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let lockURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/QuotaBar/instance.lock")
            instanceLock = try SingleInstanceLock.acquire(at: lockURL)
            guard instanceLock != nil else {
                DistributedNotificationCenter.default().postNotificationName(reopenNotification, object: nil, userInfo: nil, deliverImmediately: true)
                NSApp.terminate(nil)
                return
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "QuotaBar couldn’t start"
            alert.informativeText = "Couldn’t check whether QuotaBar is already running. \(error.localizedDescription)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenExistingInstance), name: reopenNotification, object: nil)
        installApplicationMenu()
        let item = NSStatusBar.system.statusItem(withLength: StatusItemLayout.length(
            display: model.preferences.menuDisplay, showAnthropic: model.showAnthropic
        ))
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
            button.font = StatusItemLayout.font
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
            showUsage()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let length = StatusItemLayout.length(display: model.preferences.menuDisplay, showAnthropic: model.showAnthropic)
        if statusItem?.length != length { statusItem?.length = length }
        let symbol: String
        if model.snapshot == nil { symbol = model.errorMessage == nil ? "gauge.with.dots.needle.50percent" : "exclamationmark.circle" }
        else if model.isStale { symbol = "clock.arrow.circlepath" }
        else { symbol = "chart.donut" }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "QuotaBar")
        image?.isTemplate = true
        image?.size = StatusItemLayout.imageSize
        button.image = model.preferences.menuDisplay == .iconOnly ? image : nil
        let codexTitle = UsageFormatting.menuTitle(snapshot: model.snapshot, preferences: model.preferences, now: model.now, isStale: model.isStale)
        let anthropicTitle = UsageFormatting.menuTitle(snapshot: model.anthropicSnapshot, preferences: model.preferences, now: model.now, isStale: model.isAnthropicStale)
        button.title = model.preferences.menuDisplay == .iconOnly ? "" : StatusItemLayout.title(
            codex: codexTitle, anthropic: anthropicTitle, showAnthropic: model.showAnthropic
        )
        // Let the menu bar choose its contrasting foreground, including on dark wallpapers.
        // Warning colors belong in the panel, not in the system status button.
        button.contentTintColor = nil
        var tooltip = UsageFormatting.tooltip(snapshot: model.snapshot, preferences: model.preferences, now: model.now, isStale: model.isStale)
        if model.showAnthropic {
            tooltip += "\n\n" + UsageFormatting.tooltip(snapshot: model.anthropicSnapshot, preferences: model.preferences, now: model.now, isStale: model.isAnthropicStale, provider: "Anthropic / Claude")
        }
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

    /// A regular window remains reachable even when macOS overflows the menu item.
    func showUsage() {
        popover.performClose(nil)
        if usageWindow == nil {
            let controller = NSHostingController(rootView: PopoverView(model: model, openPreferences: { [weak self] in
                self?.showPreferences()
            }))
            let window = NSWindow(contentViewController: controller)
            window.title = "QuotaBar Usage"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            usageWindow = window
        }
        model.tick()
        NSApp.activate(ignoringOtherApps: true)
        usageWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showUsage()
        return true
    }

    @objc private func reopenExistingInstance() { showUsage() }

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
        DistributedNotificationCenter.default().removeObserver(self)
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
