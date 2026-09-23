import AppKit
import Observation
import ServiceManagement
import UsageCore

@Observable
final class AppModel {
    var anthropicSnapshot: UsageSnapshot?
    var anthropicError: String?
    var isAnthropicRefreshing = false
    var showAnthropic: Bool {
        didSet {
            UserDefaults.standard.set(showAnthropic, forKey: "QuotaBar.showAnthropic")
            if showAnthropic { refreshAnthropic() }
            else {
                anthropicTask?.cancel()
                claudeClient.stop()
                claudeClient = ClaudeClient(executablePath: claudeExecutablePath)
                isAnthropicRefreshing = false
                anthropicSnapshot = nil
                anthropicError = nil
            }
            onChange?()
        }
    }
    var claudeExecutablePath: String
    var snapshot: UsageSnapshot?
    var isRefreshing = false
    var isSigningIn = false
    var errorMessage: String?
    var now = Date()
    var loginAtStartup = SMAppService.mainApp.status == .enabled
    var loginStatusMessage: String?
    var preferences: UsagePreferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) {
                UserDefaults.standard.set(data, forKey: Self.preferencesKey)
            }
            if oldValue.refreshMinutes != preferences.refreshMinutes {
                nextAnthropicRefresh = Date().addingTimeInterval(Double(preferences.refreshMinutes * 60))
                nextRefreshAt = Date().addingTimeInterval(Double(preferences.refreshMinutes * 60))
            }
            onChange?()
        }
    }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var claudeClient: ClaudeClient
    @ObservationIgnored private var anthropicTask: Task<Void, Never>?
    @ObservationIgnored private var nextAnthropicRefresh = Date.distantPast
    @ObservationIgnored private var anthropicLastAttempt = Date.distantPast
    @ObservationIgnored private var client: CodexClient
    @ObservationIgnored private var authMonitor: CodexAuthMonitor
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var nextRefreshAt = Date.distantPast
    @ObservationIgnored private var lastAttemptAt = Date.distantPast
    @ObservationIgnored private var operationGeneration = 0
    @ObservationIgnored private let isDemo: Bool
    private static let preferencesKey = "QuotaBar.preferences.v1"

    init(demo: Bool = false, client: CodexClient? = nil, authMonitor: CodexAuthMonitor = CodexAuthMonitor(), claudeClient: ClaudeClient? = nil, anthropicEnabled: Bool? = nil) {
        var saved = UserDefaults.standard.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(UsagePreferences.self, from: $0) } ?? UsagePreferences()
        saved.normalize()
        showAnthropic = anthropicEnabled ?? (UserDefaults.standard.object(forKey: "QuotaBar.showAnthropic") as? Bool ?? true)
        let savedClaudePath = UserDefaults.standard.string(forKey: "QuotaBar.claudeExecutablePath") ?? ""
        claudeExecutablePath = savedClaudePath
        self.claudeClient = claudeClient ?? ClaudeClient(executablePath: savedClaudePath)
        preferences = saved
        self.client = client ?? CodexClient(executablePath: saved.executablePath.isEmpty ? nil : saved.executablePath)
        self.authMonitor = authMonitor
        isDemo = demo
        if demo {
            anthropicSnapshot = UsageSnapshot(planName: "Max · Demo", windows: [
                UsageWindow(id: "session", title: "Session", usedPercent: 16, durationMinutes: 300, resetsAt: Date().addingTimeInterval(8_200)),
                UsageWindow(id: "weekly", title: "Weekly", usedPercent: 34, durationMinutes: 10_080, resetsAt: Date().addingTimeInterval(220_000)),
            ], fetchedAt: Date())
            snapshot = UsageSnapshot(planName: "Pro · Demo", windows: [
                UsageWindow(id: "primary", title: "Session", usedPercent: 28, durationMinutes: 300, resetsAt: Date().addingTimeInterval(7_620)),
                UsageWindow(id: "secondary", title: "Weekly", usedPercent: 49, durationMinutes: 10_080, resetsAt: Date().addingTimeInterval(342_000))
            ], fetchedAt: Date(), accountEmail: "demo@example.com")
        }
    }

    var executableAvailable: Bool {
        CodexClient.locateExecutable(override: preferences.executablePath.isEmpty ? nil : preferences.executablePath) != nil
    }

    var isStale: Bool {
        guard let snapshot else { return false }
        return errorMessage != nil || now.timeIntervalSince(snapshot.fetchedAt) > Double(max(180, preferences.refreshMinutes * 120))
            || snapshot.windows.contains { $0.awaitsResetConfirmation(at: now) }
    }

    var selectedWindow: UsageWindow? { preferences.trackedWindow.select(from: snapshot) }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        refresh()
    }

    func tick() {
        now = Date()
        if discardChangedAccount() { refreshCodex() }
        let resetCrossed = snapshot?.windows.contains { window in
            guard let reset = window.resetsAt else { return false }
            return reset <= now && reset > lastAttemptAt
        } ?? false
        if now >= nextRefreshAt || resetCrossed { refreshCodex() }
        let anthropicResetCrossed = anthropicSnapshot?.windows.contains {
            guard let reset = $0.resetsAt else { return false }
            return reset <= now && reset > anthropicLastAttempt
        } ?? false
        if now >= nextAnthropicRefresh || anthropicResetCrossed { refreshAnthropic() }
        onChange?()
    }

    func refresh() {
        refreshAnthropic()
        refreshCodex()
    }

    private func refreshCodex() {
        guard !isSigningIn, !isDemo else { return }
        _ = discardChangedAccount()
        guard !isRefreshing else { return }
        isRefreshing = true
        let generation = operationGeneration
        lastAttemptAt = Date()
        onChange?()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                // A fresh process also picks up sign-ins kept in the macOS Keychain.
                let result = try await client.fetchUsage(reloadAccount: true)
                guard !Task.isCancelled, generation == operationGeneration else { return }
                if discardChangedAccount() { refreshCodex(); return }
                snapshot = result
                errorMessage = nil
            } catch {
                guard !Task.isCancelled, generation == operationGeneration else { return }
                if discardChangedAccount() { refreshCodex(); return }
                if let connectionError = error as? CodexClientError,
                   connectionError == .signInRequired || connectionError == .unsupportedAccount {
                    snapshot = nil
                }
                errorMessage = error.localizedDescription
            }
            now = Date()
            nextRefreshAt = now.addingTimeInterval(Double(preferences.refreshMinutes * 60))
            isRefreshing = false
            onChange?()
        }
    }

    /// Changes to the shared local sign-in invalidate both displayed and in-flight usage.
    /// Leave the connection alive during our own browser login so its callback can finish.
    @discardableResult
    private func discardChangedAccount() -> Bool {
        guard !isDemo, !isSigningIn, authMonitor.consumeChange() else { return false }
        operationGeneration += 1
        refreshTask?.cancel()
        client.stop()
        isRefreshing = false
        snapshot = nil
        errorMessage = nil
        return true
    }

    func signIn() {
        guard !isSigningIn, !isRefreshing, !isDemo else { return }
        isSigningIn = true
        let generation = operationGeneration
        errorMessage = nil
        snapshot = nil
        onChange?()
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == operationGeneration {
                    isSigningIn = false
                    onChange?()
                }
            }
            do {
                let url = try await client.startSignIn()
                guard !Task.isCancelled, generation == operationGeneration else { return }
                guard NSWorkspace.shared.open(url) else {
                    errorMessage = "Couldn’t open the sign-in page. Check your default browser and try again."
                    return
                }
                // Keep the callback server alive until this login attempt completes.
                for _ in 0..<60 {
                    try await Task.sleep(for: .seconds(3))
                    if try client.isSignInComplete() {
                        guard !Task.isCancelled, generation == operationGeneration else { return }
                        isSigningIn = false
                        refresh()
                        return
                    }
                    try Task.checkCancellation()
                }
                client.stop()
                errorMessage = "Sign-in timed out. Click Connect ChatGPT to open a new sign-in page."
            } catch {
                if !Task.isCancelled, generation == operationGeneration { errorMessage = error.localizedDescription }
            }
        }
    }

    func applyExecutablePath() {
        operationGeneration += 1
        refreshTask?.cancel()
        signInTask?.cancel()
        client.stop()
        var normalized = preferences
        normalized.normalize()
        preferences = normalized
        client = CodexClient(executablePath: preferences.executablePath.isEmpty ? nil : preferences.executablePath)
        isRefreshing = false
        isSigningIn = false
        snapshot = nil
        refresh()
    }

    var isAnthropicStale: Bool {
        guard let anthropicSnapshot else { return false }
        return now.timeIntervalSince(anthropicSnapshot.fetchedAt) > Double(max(180, preferences.refreshMinutes * 120))
            || anthropicSnapshot.windows.contains { $0.awaitsResetConfirmation(at: now) }
    }

    func refreshAnthropic() {
        guard showAnthropic, !isAnthropicRefreshing, !isDemo else { return }
        isAnthropicRefreshing = true
        anthropicLastAttempt = Date()
        onChange?()
        anthropicTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await claudeClient.fetchUsage()
                guard !Task.isCancelled, showAnthropic else { return }
                anthropicSnapshot = result
                anthropicError = nil
            } catch {
                guard !Task.isCancelled, showAnthropic else { return }
                // A fresh CLI may represent a changed account; never retain another account's quota on failure.
                anthropicSnapshot = nil
                anthropicError = error.localizedDescription
            }
            now = Date()
            nextAnthropicRefresh = now.addingTimeInterval(Double(preferences.refreshMinutes * 60))
            isAnthropicRefreshing = false
            onChange?()
        }
    }

    func applyClaudeExecutablePath() {
        anthropicTask?.cancel()
        claudeClient.stop()
        claudeExecutablePath = claudeExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(claudeExecutablePath, forKey: "QuotaBar.claudeExecutablePath")
        claudeClient = ClaudeClient(executablePath: claudeExecutablePath)
        anthropicSnapshot = nil
        anthropicError = nil
        isAnthropicRefreshing = false
        refreshAnthropic()
    }

    func openAnthropicDashboard() {
        if let url = URL(string: "https://claude.ai/settings/usage") { NSWorkspace.shared.open(url) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            syncLoginStatus()
        } catch {
            loginStatusMessage = error.localizedDescription
            loginAtStartup = SMAppService.mainApp.status == .enabled
        }
    }

    func syncLoginStatus() {
        let status = SMAppService.mainApp.status
        loginAtStartup = status == .enabled
        loginStatusMessage = status == .requiresApproval
            ? "Allow QuotaBar in System Settings → General → Login Items." : nil
    }

    func openDashboard() {
        if let url = URL(string: "https://chatgpt.com/codex/settings/usage") { NSWorkspace.shared.open(url) }
    }

    func openInstallInstructions() {
        if let url = URL(string: "https://developers.openai.com/codex/cli") { NSWorkspace.shared.open(url) }
    }

    func stop() {
        operationGeneration += 1
        anthropicTask?.cancel()
        claudeClient.stop()
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        signInTask?.cancel()
        client.stop()
    }

    func quit() { NSApp.terminate(nil) }
}
