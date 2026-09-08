import AppKit
import Observation
import ServiceManagement
import UsageCore

@Observable
final class AppModel {
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
                nextRefreshAt = Date().addingTimeInterval(Double(preferences.refreshMinutes * 60))
            }
            onChange?()
        }
    }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var client: CodexClient
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var nextRefreshAt = Date.distantPast
    @ObservationIgnored private var lastAttemptAt = Date.distantPast
    @ObservationIgnored private var operationGeneration = 0
    @ObservationIgnored private let isDemo: Bool
    private static let preferencesKey = "QuotaBar.preferences.v1"

    init(demo: Bool = false) {
        var saved = UserDefaults.standard.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(UsagePreferences.self, from: $0) } ?? UsagePreferences()
        saved.normalize()
        preferences = saved
        client = CodexClient(executablePath: saved.executablePath.isEmpty ? nil : saved.executablePath)
        isDemo = demo
        if demo {
            snapshot = UsageSnapshot(planName: "Pro · Demo", windows: [
                UsageWindow(id: "primary", title: "Session", usedPercent: 28, durationMinutes: 300, resetsAt: Date().addingTimeInterval(7_620)),
                UsageWindow(id: "secondary", title: "Weekly", usedPercent: 49, durationMinutes: 10_080, resetsAt: Date().addingTimeInterval(342_000))
            ], fetchedAt: Date())
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
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        refresh()
    }

    func tick() {
        now = Date()
        let resetCrossed = snapshot?.windows.contains { window in
            guard let reset = window.resetsAt else { return false }
            return reset <= now && reset > lastAttemptAt
        } ?? false
        if now >= nextRefreshAt || resetCrossed { refresh() }
        onChange?()
    }

    func refresh() {
        guard !isRefreshing, !isSigningIn, !isDemo else { return }
        isRefreshing = true
        lastAttemptAt = Date()
        onChange?()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.fetchUsage()
                guard !Task.isCancelled else { return }
                snapshot = result
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
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
                // The CLI owns the browser callback and credentials. Read only the resulting quota.
                for _ in 0..<60 {
                    try await Task.sleep(for: .seconds(3))
                    if let result = try? await client.fetchUsage() {
                        guard !Task.isCancelled, generation == operationGeneration else { return }
                        snapshot = result
                        errorMessage = nil
                        now = Date()
                        nextRefreshAt = now.addingTimeInterval(Double(preferences.refreshMinutes * 60))
                        return
                    }
                    try Task.checkCancellation()
                }
                errorMessage = "Sign-in is still pending. Finish in your browser, then click Refresh."
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
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        signInTask?.cancel()
        client.stop()
    }

    func quit() { NSApp.terminate(nil) }
}
