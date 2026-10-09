import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var model: AccessModel
    @ObservedObject var filter: NetworkFilter
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                if model.snapshot.canReadTCC {
                    Label("Revoke can read the permissions list.", systemImage: "checkmark.circle.fill")
                        .help("Full Disk Access is on, so Revoke can see which apps have Device Control or Screen Recording.")
                } else {
                    Text("Revoke needs Full Disk Access to show which apps have Device Control or Screen Recording. After switching it on, choose Quit & Reopen. Revoke only reads the permissions list: macOS doesn't let any app edit it.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Full Disk Access Settings") { NSWorkspace.shared.open(Pane.fullDiskAccessURL) }
                        .help("Opens Privacy & Security > Full Disk Access in System Settings. Switch Revoke on there.")
                }
            } header: {
                Text("Full Disk Access")
            }

            Section {
                localNetwork
            } header: {
                Text("Local Network")
            } footer: {
                Text("macOS lets only System Settings change its Local Network switch, so Revoke blocks the traffic itself, with a network filter like LuLu's. Revoked apps can't connect to devices on your network, commands they start included, but still reach the internet and servers on this Mac. Bonjour discovery isn't blocked, because macOS does it on the app's behalf.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("When a watched app quits", isOn: $settings.revokeOnQuit)
                    .help("When the last open app from a developer quits, revoke access for all of that developer's watched apps.")
                Toggle("After a time limit", isOn: $settings.revokeAfterLimit)
                    .help("Revoke a watched app's access once it has had it for the time limit below.")
                Picker("Time limit", selection: $settings.limitMinutes) {
                    ForEach(Settings.timeLimits, id: \.self) { Text(Settings.describe(minutes: $0)).tag($0) }
                }
                .disabled(!settings.revokeAfterLimit)
                .help("How long a watched app keeps access after it's switched on.")
                Toggle("When the Mac sleeps or the screen locks", isOn: $settings.revokeOnSleepOrLock)
                    .help("Revoke every watched app's access when you step away.")
            } header: {
                Text("Revoke automatically")
            } footer: {
                Text("Quitting an app revokes every watched app from the same developer once none of them are open, so quitting ChatGPT also covers Codex Computer Use. The time limit counts from when access was switched on.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.knownClients, id: \.self) { client in
                    Toggle(isOn: Binding(get: { settings.isWatched(client) },
                                         set: { settings.setWatched(client, $0) })) {
                        HStack(spacing: 8) {
                            Image(nsImage: AppInfo.icon(client)).resizable().frame(width: 18, height: 18)
                            Text(AppInfo.name(client))
                        }
                        .help("\(AppInfo.name(client)) (\(client.key))")
                    }
                    .help(settings.isWatched(client)
                          ? "Watched: Revoke All Watched and the automatic options cover \(AppInfo.name(client))."
                          : "Not watched: Revoke lists \(AppInfo.name(client)) but leaves its access alone.")
                }
            } header: {
                Text("Watched apps")
            } footer: {
                Text("Revoke All Watched and the automatic options cover these. Apps from Anthropic and OpenAI are watched unless you switch them off.")
                    .foregroundStyle(.secondary)
            }

            Section {
                // A custom binding rather than onChange, so correcting the toggle after a
                // failure doesn't register or unregister again.
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { setLogin($0) }))
                    .help("Start Revoke in the menu bar when you log in, so it's always watching.")
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                }
            } footer: {
                Text("Revoke uses Apple's tccutil to revoke Device Control and Screen & System Audio Recording. macOS keeps granting access for System Settings.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Quit Revoke") { NSApp.terminate(nil) }
                    .help("Quits Revoke. Nothing is revoked automatically while it isn't running.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        // Login Items and Full Disk Access can change in System Settings while this
        // window is behind it, so read them again whenever it comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if launchAtLogin { loginError = nil }
            model.refresh()
        }
    }

    @ViewBuilder
    private var localNetwork: some View {
        switch filter.state {
        case .checking:
            ProgressView().controlSize(.small).help("Checking the network filter…")
        case .notInstalled:
            Text("Install Revoke's network filter to block Local Network. macOS asks you to allow it.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Install Network Filter") { filter.install() }
                .help("Installs the system extension that blocks Local Network. macOS asks you to allow it.")
        case .needsApproval:
            Text("Allow Revoke in System Settings > General > Login Items & Extensions, under Network Extensions.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Login Items & Extensions") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            }
            .help("Opens the settings where you allow Revoke's network filter.")
        case .off:
            Text("The network filter is installed but switched off.")
            Button("Turn On") { filter.enable() }
                .help("Switches the network filter on, so switching off Local Network blocks the app.")
            removeFilter
        case .on:
            Label("Revoke can block Local Network.", systemImage: "checkmark.circle.fill")
                .help("The network filter is on. Apps with Local Network switched off in the panel can't reach your network.")
            removeFilter
        case .failed(let message):
            Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { filter.install() }
                .help("Tries installing the network filter again.")
        }
    }

    /// Before Revoke is deleted, so the system extension goes with it.
    private var removeFilter: some View {
        Button("Remove Network Filter", role: .destructive) { filter.remove() }
            .help("Uninstalls the filter. Do this before deleting Revoke.")
    }

    private func setLogin(_ wanted: Bool) {
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval
                ? "Allow Revoke in System Settings → General → Login Items." : nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
