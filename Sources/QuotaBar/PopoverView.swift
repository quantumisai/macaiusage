import SwiftUI
import UsageCore

struct PopoverView: View {
    @Bindable var model: AppModel
    let openPreferences: () -> Void

    private let accent = Color(red: 0.08, green: 0.56, blue: 0.49)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let snapshot = model.snapshot, !snapshot.windows.isEmpty {
                VStack(spacing: 10) {
                    ForEach(snapshot.windows) { window in
                        usageCard(window)
                    }
                }

                if model.isStale {
                    notice("Showing last known usage. Refresh to update.", symbol: "clock.badge.exclamationmark")
                }
                if let error = model.errorMessage {
                    notice(error, symbol: "exclamationmark.triangle")
                    Button("Reconnect ChatGPT", action: model.signIn)
                        .buttonStyle(.link)
                        .disabled(model.isRefreshing || model.isSigningIn)
                }
                dashboardButton
            } else {
                connectionState
            }

            Divider()
            footer
        }
        .padding(18)
        .frame(width: 356)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().stroke(accent.opacity(0.16), lineWidth: 3.5)
                    Circle().trim(from: 0, to: 0.76)
                        .stroke(accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Circle().fill(accent).frame(width: 5, height: 5)
                }
                .frame(width: 25, height: 25)
                .accessibilityHidden(true)

                Text("QuotaBar")
                    .font(.system(size: 16, weight: .semibold))

                if let plan = model.snapshot?.planName, !plan.isEmpty {
                    Text(plan.capitalized)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(accent.opacity(0.10), in: Capsule())
                }

                Spacer(minLength: 0)

                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 23, height: 23)
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing || model.isSigningIn)
                .help("Refresh usage")
                .accessibilityLabel("Refresh usage")
                .keyboardShortcut("r", modifiers: .command)

                Button(action: openPreferences) {
                    Image(systemName: "gearshape")
                        .frame(width: 23, height: 23)
                }
                .buttonStyle(.borderless)
                .help("QuotaBar settings")
                .accessibilityLabel("Open QuotaBar settings")
                .keyboardShortcut(",", modifiers: .command)
            }

            Text("Codex usage from your ChatGPT subscription")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func usageCard(_ window: UsageWindow) -> some View {
        let awaitingReset = window.awaitsResetConfirmation(at: model.now)
        let isLow = window.remainingPercent <= Double(model.preferences.warningThreshold)
        let color: Color = awaitingReset ? .secondary : (isLow ? .orange : accent)

        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(window.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if awaitingReset {
                    Text("UPDATE NEEDED")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if isLow {
                    Label("Running low", systemImage: "exclamationmark.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(awaitingReset ? "—" : UsageFormatting.percent(window.remainingPercent))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(awaitingReset ? Color.secondary : Color.primary)
                Text(awaitingReset ? "awaiting update" : "remaining")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.12))
                    if !awaitingReset {
                        Capsule().fill(color)
                            .frame(width: geometry.size.width * window.remainingPercent / 100)
                    }
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .padding(.top, 2)
                Text(resetText(for: window))
                    .font(.system(size: 11))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func resetText(for window: UsageWindow) -> String {
        if window.awaitsResetConfirmation(at: model.now) {
            return "Reset due · waiting for refreshed usage"
        }
        return UsageFormatting.reset(window.resetsAt, style: model.preferences.resetDisplay, now: model.now)
    }

    private var connectionState: some View {
        VStack(spacing: 13) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(accent)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text(model.isRefreshing ? "Checking your usage…" : "Your usage, at a glance")
                    .font(.system(size: 16, weight: .semibold))
                Text(model.executableAvailable
                     ? "Connect your ChatGPT account to see your remaining Codex allowance and reset times."
                     : "Install Codex, then connect your ChatGPT account to see your allowance here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isSigningIn || model.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.isSigningIn ? "Complete sign-in in your browser…" : "Fetching subscription limits…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.errorMessage {
                notice(error, symbol: "exclamationmark.triangle")
            }

            Button(action: model.signIn) {
                Text("Connect ChatGPT")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .controlSize(.large)
            .disabled(!model.executableAvailable || model.isSigningIn || model.isRefreshing)

            if !model.executableAvailable {
                Button("Install Codex…", action: model.openInstallInstructions)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var dashboardButton: some View {
        Button(action: model.openDashboard) {
            HStack {
                Text("Open usage dashboard")
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Refreshing…")
            } else if let snapshot = model.snapshot {
                Circle()
                    .fill(model.isStale ? Color.orange : accent)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(freshnessText(snapshot.fetchedAt))
                    .help(snapshot.fetchedAt.formatted(date: .abbreviated, time: .standard))
            } else {
                Text("Waiting for connection")
            }

            Spacer()

            Button("Quit", action: model.quit)
                .buttonStyle(.plain)
                .help("Quit QuotaBar")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func freshnessText(_ date: Date) -> String {
        let minutes = max(0, Int(model.now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "Updated \(hours)h ago" }
        return "Updated \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func notice(_ message: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .padding(.top, 1)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
