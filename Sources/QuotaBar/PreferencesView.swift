import SwiftUI
import UsageCore

struct PreferencesView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Display", selection: $model.preferences.menuDisplay) {
                        ForEach(MenuDisplay.allCases, id: \.self) { display in
                            Text(display.label).tag(display)
                        }
                    }
                    Picker("Track", selection: $model.preferences.trackedWindow) {
                        ForEach(TrackedWindow.allCases, id: \.self) { window in
                            Text(window.label).tag(window)
                        }
                    }
                    .disabled(model.preferences.menuDisplay == .bothWindows || model.preferences.menuDisplay == .iconOnly)

                    Toggle("Show usage details on hover", isOn: $model.preferences.showHoverDetails)
                } header: {
                    Text("Menu bar")
                } footer: {
                    Text("Lowest remaining follows the allowance closest to its limit. Unavailable windows appear as —.")
                }

                Section("Usage & resets") {
                    Picker("Reset time", selection: $model.preferences.resetDisplay) {
                        ForEach(ResetDisplay.allCases, id: \.self) { display in
                            Text(display.label).tag(display)
                        }
                    }

                    Picker("Refresh every", selection: $model.preferences.refreshMinutes) {
                        ForEach([1, 2, 5, 15], id: \.self) { minutes in
                            Text("\(minutes) \(minutes == 1 ? "minute" : "minutes")").tag(minutes)
                        }
                    }

                    LabeledContent("Warn below") {
                        HStack(spacing: 9) {
                            Slider(value: warningThreshold, in: 0...50, step: 5)
                                .frame(width: 125)
                                .accessibilityLabel("Warning threshold, percent remaining")
                                .accessibilityValue("\(model.preferences.warningThreshold) percent")
                            Text("\(model.preferences.warningThreshold)% left")
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }

                Section("General") {
                    Toggle("Launch QuotaBar at login", isOn: Binding(
                        get: { model.loginAtStartup },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    if let message = model.loginStatusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Codex executable")
                        HStack(spacing: 8) {
                            TextField("Automatic detection", text: $model.preferences.executablePath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit(model.applyExecutablePath)
                                .accessibilityLabel("Custom Codex executable path")
                            Button("Apply", action: model.applyExecutablePath)
                        }
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Leave blank to find Codex automatically. QuotaBar uses your existing Codex sign-in.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Codex usage from your ChatGPT subscription")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Usage dashboard", action: model.openDashboard)
                    .buttonStyle(.link)
            }
            .font(.system(size: 10))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 680)
    }

    private var warningThreshold: Binding<Double> {
        Binding(
            get: { Double(model.preferences.warningThreshold) },
            set: { model.preferences.warningThreshold = Int($0.rounded()) }
        )
    }
}
