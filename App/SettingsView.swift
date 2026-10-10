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
                        .tip("Full Disk Access is on, so Revoke can see which apps have each permission.")
                } else {
                    Text("Revoke needs Full Disk Access to show which apps have Device Control, Screen Recording, and the other permissions. After switching it on, choose Quit & Reopen. Revoke only reads the permissions list: macOS doesn't let any app edit it.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Full Disk Access Settings") { NSWorkspace.shared.open(Pane.fullDiskAccessURL) }
                        .tip("Opens Privacy & Security > Full Disk Access in System Settings. Switch Revoke on there.")
                }
            } header: {
                Text("Full Disk Access")
            }

            Section {
                localNetwork
            } header: {
                Text("Local Network")
            } footer: {
                Text("macOS lets only System Settings change its Local Network switch, so Revoke blocks the traffic itself, with a network filter like LuLu's. Revoked apps can't connect to devices on your network, commands they start included, and those devices can't connect to them, but the apps still reach the internet and servers on this Mac. Bonjour discovery isn't blocked, because macOS does it on the app's behalf.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Web pages, emails, and documents can open an agent with a link (claude://, codex://, claude-cli://) or a file (.skill), carrying instructions for it, even while it's quit. Switch an app's Links off in the panel and macOS opens Revoke instead, which shows you the link and opens the app only if you say yes.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Give All Links Back") { model.giveAllLinksBack() }
                    .disabled(settings.linksBlocked.isEmpty && settings.linkOwners.isEmpty)
                    .tip("Makes each app the handler for its own links and files again, as before Revoke stood in. Do this before deleting Revoke.")
            } header: {
                Text("Links")
            } footer: {
                Text("Link schemes change hands without a word. macOS asks you to confirm each file type, when Revoke takes it and when it gives it back, so the automatic options leave file types alone.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("When a watched app quits", isOn: $settings.revokeOnQuit)
                    .tip("When the last open app from a developer quits, revoke access for all of that developer's watched apps.")
                Toggle("After a time limit", isOn: $settings.revokeAfterLimit)
                    .tip("Revoke a watched app's access once it has had it for the time limit below.")
                Picker("Time limit", selection: $settings.limitMinutes) {
                    ForEach(Settings.timeLimits, id: \.self) { Text(Settings.describe(minutes: $0)).tag($0) }
                }
                .disabled(!settings.revokeAfterLimit)
                .tip("How long a watched app keeps access after it's switched on.")
                Toggle("When the Mac sleeps or the screen locks", isOn: $settings.revokeOnSleepOrLock)
                    .tip("Revoke every watched app's access when you step away.")
            } header: {
                Text("Revoke automatically")
            } footer: {
                Text("Quitting an app revokes every watched app from the same developer once none of them are open, so quitting ChatGPT also covers Codex Computer Use. The time limit counts from when access was switched on. Each of these switches Links off too, and leaves running apps running.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.knownClients, id: \.self) { client in
                    Toggle(isOn: Binding(get: { settings.isWatched(client) },
                                         set: { settings.setWatched(client, $0) })) {
                        HStack(spacing: 8) {
                            Image(nsImage: AppInfo.icon(client)).resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(AppInfo.name(client))
                                if let role = AppInfo.role(client) {
                                    Text(role).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .tip(settings.isWatched(client)
                          ? "Watched: Revoke All Watched and the automatic options cover \(AppInfo.name(client)) (\(client.key))."
                          : "Not watched: Revoke lists \(AppInfo.name(client)) (\(client.key)) but leaves its access alone.")
                }
            } header: {
                Text("Watched apps")
            } footer: {
                Text("Revoke All Watched and the automatic options cover these. Apps from Anthropic and OpenAI are watched unless you switch them off.")
                    .foregroundStyle(.secondary)
            }

            if !settings.hidden.isEmpty {
                Section {
                    ForEach(settings.hiddenClients.sorted { AppInfo.name($0).localizedStandardCompare(AppInfo.name($1)) == .orderedAscending }, id: \.self) { client in
                        HStack(spacing: 8) {
                            Image(nsImage: AppInfo.icon(client)).resizable().frame(width: 18, height: 18)
                            Text(AppInfo.name(client))
                            Spacer()
                            Button("Show") { settings.setHidden(client, false) }
                                .accessibilityLabel("Show \(AppInfo.name(client))")
                                .tip("Lists \(AppInfo.name(client)) (\(client.key)) under other apps with access again.")
                        }
                    }
                } header: {
                    Text("Hidden apps")
                } footer: {
                    Text("Hidden from the panel's list of other apps with access. Hiding an app doesn't change its access. Right-click an app in the panel to hide it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                // A custom binding rather than onChange, so correcting the toggle after a
                // failure doesn't register or unregister again.
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { setLogin($0) }))
                    .tip("Start Revoke in the menu bar when you log in, so it's always watching.")
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                }
            } footer: {
                Text("Revoke uses Apple's tccutil to revoke Device Control and Screen & System Audio Recording. macOS keeps granting access for System Settings.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Quit Revoke") { NSApp.terminate(nil) }
                    .tip("Quits Revoke. Nothing is stopped or revoked automatically while Revoke isn't running.")
            }

            Section {
                ForEach(Self.cantDo, id: \.self) { line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("What macOS doesn't let Revoke do")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 700)
        // Login Items and Full Disk Access can change in System Settings while this
        // window is behind it, so read them again whenever it comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if launchAtLogin { loginError = nil }
            model.refresh()
        }
    }

    /// The same list as the README's, kept short.
    private static let cantDo = [
        "Only you can switch access on, in System Settings. Revoke can only take it away.",
        "Location Services keeps its list where only macOS can read it, and tccutil can't reset it, so Revoke doesn't show or change it.",
        "Open at Login and Allow in the Background are kept where only macOS can change them. Remove an app there in System Settings › General › Login Items & Extensions.",
        "Automation, the camera and microphone, files and folders, and the rest under Other are kept where only Apple's own software can see them. Revoke can reset them, but can't show who has them.",
        "macOS doesn't tell other apps whether an app's window was closed, minimized, or moved to another Space, so Revoke can't stop an app when its last window closes, as Revoke for Windows does. It acts when the app quits.",
        "Stopping an app reaches what it started while they're still its children. A process it left behind, which macOS hands to launchd, can't be traced back to it.",
        "Links only cover what goes through macOS's link and file handling. A process already running as you can start an app directly.",
        "Command-line tools listed by path, rather than by bundle ID, can only be changed in System Settings.",
    ]

    @ViewBuilder
    private var localNetwork: some View {
        switch filter.state {
        case .checking:
            ProgressView().controlSize(.small).tip("Checking the network filter…")
        case .notInstalled:
            Text("Install Revoke's network filter to block Local Network. macOS asks you to allow it.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Install Network Filter") { filter.install() }
                .tip("Installs the system extension that blocks Local Network. macOS asks you to allow it.")
        case .needsApproval:
            Text("Allow Revoke in System Settings > General > Login Items & Extensions, under Network Extensions.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Login Items & Extensions") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            }
            .tip("Opens the settings where you allow Revoke's network filter.")
        case .off:
            Text("The network filter is installed but switched off.")
            Button("Turn On") { filter.enable() }
                .tip("Switches the network filter on, so switching off Local Network blocks the app.")
            removeFilter
        case .on:
            Label("Revoke can block Local Network.", systemImage: "checkmark.circle.fill")
                .tip("The network filter is on. Apps with Local Network switched off in the panel can't reach your network.")
            removeFilter
        case .failed(let message):
            Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { filter.install() }
                .tip("Tries installing the network filter again.")
        }
    }

    /// Before Revoke is deleted, so the system extension goes with it.
    private var removeFilter: some View {
        Button("Remove Network Filter", role: .destructive) { filter.remove() }
            .tip("Uninstalls the filter. Do this before deleting Revoke.")
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
