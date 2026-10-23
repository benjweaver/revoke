import SwiftUI

/// The popover under the menu bar icon: one switch per app and privacy list.
struct PanelView: View {
    @ObservedObject var model: AccessModel
    @ObservedObject var settings: Settings
    @ObservedObject var filter: NetworkFilter
    /// Set from the screen the panel opens on: see PanelLayout.width(forScreenWidth:).
    var width: CGFloat = PanelLayout.preferredWidth
    let openSettings: () -> Void

    /// Past this many rows the list scrolls, so the panel stays on screen.
    private static let rowsBeforeScrolling = 10

    var body: some View {
        let watched = model.rows(watched: true)
        let others = model.rows(watched: false)
        let leftovers = model.leftoverRows
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.snapshot.canReadTCC { fullDiskAccessNotice }

            VStack(alignment: .leading, spacing: 6) {
                columnTitles
                let list = appList(watched: watched, others: others, leftovers: leftovers)
                if watched.count + others.count + leftovers.count > Self.rowsBeforeScrolling {
                    ScrollView { list }.frame(height: 420)
                } else {
                    list
                }
            }

            Divider()
            HStack {
                Button("Revoke All Watched") { model.revokeWatched(reason: nil) }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .disabled(model.isRevoking)
                    .tip("Switches off every access switch the watched apps have, Links included. Running apps keep going but have to ask again; Stop All Apps stops them.")
                Button("Stop All Apps") { model.stopAll() }
                    .buttonStyle(PanelButtonStyle(prominent: false))
                    .disabled(model.isRevoking)
                    .tip("Stops every watched app, its helpers, and everything they started, such as an agent's shells and tools. The switches stay as they are.")
                if model.isRevoking {
                    ProgressView().controlSize(.small).tip("Revoking…")
                }
            }
            if let activity = model.lastActivity {
                Text("\(activity.date.formatted(date: .omitted, time: .shortened)) · \(activity.text)")
                    .font(.caption)
                    .foregroundStyle(activity.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .tip(activity.isError ? "The last thing Revoke tried failed." : "The last thing Revoke did.")
            }
            Text("Switching access on opens System Settings, because macOS only lets you grant it there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PanelLayout.padding)
        .frame(width: width)
        .tipHost()
    }

    /// The titles sit outside the list so they stay put while it scrolls.
    private var columnTitles: some View {
        HStack(spacing: PanelLayout.columnSpacing) {
            Spacer()
            ForEach(Pane.allCases) { pane in
                columnTitle(symbol: pane.symbol, title: pane.shortTitle, tip: pane.explanation)
            }
            columnTitle(
                symbol: "switch.2", title: "All Access",
                tip: "All access: switches off every access switch the app has, Links included, and resets Other. Running stays as it is.")
        }
    }

    private func columnTitle(symbol: String, title: String, tip: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
            Text(title).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .frame(width: PanelLayout.columnWidth, alignment: .top)
        .tip(tip)
    }

    private func appList(watched: [Row], others: [Row], leftovers: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            watchedHeader(watched)
            if watched.isEmpty {
                Text("No watched apps are installed or running.").foregroundStyle(.secondary)
            }
            ForEach(watched) { row($0) }

            if !others.isEmpty {
                sectionTitle("Other apps with access").padding(.top, 6)
                    .tip("Apps you don't watch that have Device Control, Screen Recording, Input Monitoring, or Automation. Revoke lists them but never revokes them by itself. Right-click one to watch it or hide it.")
                ForEach(others) { row($0) }
            }

            if !leftovers.isEmpty {
                HStack {
                    sectionTitle("Deleted apps")
                    Spacer()
                    Button("Remove All") { model.removeLeftovers() }
                        .buttonStyle(PanelButtonStyle(prominent: false))
                        .disabled(model.isRevoking)
                        .tip("Removes every deleted app's leftover entries from the privacy lists.")
                }
                .padding(.top, 6)
                Text("macOS kept these permissions after the apps were deleted or replaced. Nothing installed can use them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(leftovers) { leftoverRow($0) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Revoke").font(.headline)
                Text(model.statusText).font(.subheadline).foregroundStyle(.secondary)
                    .tip(lockHelp)
            }
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .tip("Settings")
            .accessibilityLabel("Settings")
        }
    }

    /// What the menu bar lock is showing, and why.
    private var lockHelp: String {
        if !model.snapshot.canReadTCC {
            return "Revoke can't read the permissions list without Full Disk Access, so the lock shows a warning."
        }
        if !model.exposedNames.isEmpty || !model.runningNames.isEmpty {
            return "The lock is open while a watched app is running or has Device Control, Screen Recording, Input Monitoring, or Automation."
        }
        return "The lock is closed: no watched app is running or has Device Control, Screen Recording, Input Monitoring, or Automation."
    }

    private var fullDiskAccessNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Revoke can't see who has access yet", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
            Text("Give it Full Disk Access to read the permissions list, then choose Quit & Reopen. It only reads the list: macOS doesn't let any app edit it. Revoking works either way.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Full Disk Access Settings") { NSWorkspace.shared.open(Pane.fullDiskAccessURL) }
                .buttonStyle(PanelButtonStyle(prominent: false))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func watchedHeader(_ watched: [Row]) -> some View {
        HStack(spacing: PanelLayout.columnSpacing) {
            sectionTitle("Watched")
                .tip("Apps Revoke looks after: Revoke All Watched and the automatic options cover them. Right-click one to stop it or stop watching it, or choose in Settings.")
                .frame(maxWidth: .infinity, alignment: .leading)
            if !watched.isEmpty {
                ForEach(Pane.allCases) { pane in
                    watchedCell(watched, pane).frame(width: PanelLayout.columnWidth)
                }
                watchedAllAccessCell(watched).frame(width: PanelLayout.columnWidth)
            }
        }
    }

    private func row(_ row: Row) -> some View {
        HStack(spacing: PanelLayout.columnSpacing) {
            label(row, caption: [
                AppInfo.role(row.client),
                row.deadline.map { "Revokes at \($0.formatted(date: .omitted, time: .shortened))" },
            ].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
            ForEach(Pane.allCases) { pane in
                cell(row, pane).frame(width: PanelLayout.columnWidth)
            }
            rowAllAccessCell(row).frame(width: PanelLayout.columnWidth)
        }
        .contentShape(Rectangle())
        .contextMenu {
            // For an app, or a helper it left behind, running with no window to close.
            if row.isRunning || model.isRunning(row.client) {
                Button("Stop App") { model.stop(row.client) }
                    .disabled(model.isRevoking)
                Divider()
            }
            if settings.isWatched(row.client) {
                Button("Stop Watching") { settings.setWatched(row.client, false) }
            } else {
                Button("Watch") { settings.setWatched(row.client, true) }
                Button("Hide from This List") { settings.setHidden(row.client, true) }
            }
        }
    }

    /// A deleted app gets one button rather than switches: nothing it left behind
    /// is worth keeping, and none of it can be switched back on.
    private func leftoverRow(_ row: Row) -> some View {
        let on = Pane.allCases.filter(row.isAllowed).map(\.shortTitle)
        return HStack(spacing: PanelLayout.columnSpacing) {
            label(row, caption: on.isEmpty ? "Listed, switched off" : "\(on.formatted(.list(type: .and))) on")
            Button("Remove") { model.removeLeftovers([row.client]) }
                .buttonStyle(PanelButtonStyle(prominent: false))
                .disabled(model.isRevoking)
                .fixedSize()
                .tip("Remove \(row.client.key) from the privacy lists.")
        }
    }

    private func label(_ row: Row, caption: String?) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: row.icon)
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                    .tip("\(row.name) (\(row.client.key))")
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                        .tip(row.deadline == nil ? caption
                              : "The time limit in Settings switches this app's access off then.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cell(_ row: Row, _ pane: Pane) -> some View {
        if pane == .links && model.snapshot.links[row.client] == nil {
            Text("–")
                .foregroundStyle(.tertiary)
                .tip("Nothing opens \(row.name) with a link or a file.")
        } else if (pane == .running || pane == .other) && row.client.bundleID == nil {
            Text("–")
                .foregroundStyle(.tertiary)
                .tip("Only System Settings can change command-line tools listed by path.")
        } else if pane == .other {
            otherMenu(row)
        } else if !model.snapshot.canRead(pane) {
            Image(systemName: "questionmark")
                .foregroundStyle(.tertiary)
                .tip("Revoke needs Full Disk Access to see this.")
        } else {
            Toggle(pane.title, isOn: Binding(
                get: { row.isAllowed(pane) },
                set: { model.set(pane, on: $0, for: row.client) }))
                .toggleStyle(AccessSwitchStyle())
                .disabled(model.isRevoking)
                .tip(help(row, pane))
        }
    }

    @ViewBuilder
    private func watchedCell(_ watched: [Row], _ pane: Pane) -> some View {
        if pane == .links && watched.allSatisfy({ model.snapshot.links[$0.client] == nil }) {
            Text("–")
                .foregroundStyle(.tertiary)
                .tip("No watched app registers links or files.")
        } else if pane == .other {
            watchedOtherMenu(watched)
        } else if !model.snapshot.canRead(pane) {
            Image(systemName: "questionmark")
                .foregroundStyle(.tertiary)
                .tip("Revoke needs Full Disk Access to see this.")
        } else {
            let isOn = watched.contains { row in
                (pane == .localNetwork || row.client.bundleID != nil) && row.isAllowed(pane)
            }
            Toggle("All watched \(pane.title)", isOn: Binding(
                get: { isOn },
                set: { model.set(pane, on: $0, forWatched: watched) }))
                .toggleStyle(AccessSwitchStyle())
                .disabled(model.isRevoking)
                .tip(watchedHelp(watched, pane, isOn: isOn))
        }
    }

    @ViewBuilder
    private func watchedAllAccessCell(_ watched: [Row]) -> some View {
        let isOn = watched.contains { $0.hasAccess(filterIsOn: filter.isOn) }
        if !isOn && !model.snapshot.canReadTCC {
            Image(systemName: "questionmark")
                .foregroundStyle(.tertiary)
                .tip("Revoke needs Full Disk Access to see this.")
        } else {
            Toggle("All watched access", isOn: Binding(
                get: { isOn },
                set: { if !$0 { model.revokeWatched(reason: nil) } }))
                .toggleStyle(AccessSwitchStyle())
                .disabled(model.isRevoking)
                .tip(isOn
                     ? "Switches off every access switch the watched apps have, Links included, and resets Other. Running apps keep going."
                     : "Every watched app's access switches are off.")
        }
    }

    @ViewBuilder
    private func rowAllAccessCell(_ row: Row) -> some View {
        let isOn = row.hasAccess(filterIsOn: filter.isOn)
        if row.client.bundleID == nil {
            Text("–")
                .foregroundStyle(.tertiary)
                .tip("Only System Settings can change command-line tools listed by path.")
        } else if !isOn && !model.snapshot.canReadTCC {
            Image(systemName: "questionmark")
                .foregroundStyle(.tertiary)
                .tip("Revoke needs Full Disk Access to see this.")
        } else {
            Toggle("All access for \(row.name)", isOn: Binding(
                get: { isOn },
                set: { if !$0 { model.revoke([row.client], panes: Pane.access, reason: nil) } }))
                .toggleStyle(AccessSwitchStyle())
                .disabled(model.isRevoking)
                .tip(isOn
                     ? "Switches off every access switch \(row.name) has, Links included, and resets Other. Running stays as it is."
                     : "All of \(row.name)'s access switches are off.")
        }
    }

    /// Access Revoke can't see gets a menu to reset it rather than a switch, which
    /// would have nothing true to show.
    private func otherMenu(_ row: Row) -> some View {
        let access = AppInfo.otherAccess(row.client)
        return Menu {
            ForEach(access) { item in
                Button("Reset \(item.title)") { model.reset([item], for: row.client) }
                    .help(item.explanation)
            }
            Divider()
            Button("Reset All of These") { model.reset(access, for: row.client) }
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isRevoking)
        .accessibilityLabel("Reset other access for \(row.name)")
        .tip("\(row.name) can ask for \(access.map(\.title).formatted(.list(type: .and))). macOS doesn't let other apps see who has these, so this is a menu rather than a switch: reset one and \(row.name) asks again the next time it needs it. Revoke All Watched resets them all.")
    }

    private func watchedOtherMenu(_ watched: [Row]) -> some View {
        let askable = Set(watched.flatMap { AppInfo.otherAccess($0.client) })
        let access = OtherAccess.allCases.filter(askable.contains)
        let clients = watched.map(\.client)
        return Menu {
            ForEach(access) { item in
                Button("Reset \(item.title)") { model.reset([item], for: clients) }
                    .help(item.explanation)
            }
            Divider()
            Button("Reset All of These") { model.reset(access, for: clients) }
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isRevoking)
        .accessibilityLabel("Reset other access for all watched apps")
        .tip("Resets \(access.map(\.title).formatted(.list(type: .or))) for every watched app, so they ask again the next time they need it.")
    }

    private func watchedHelp(_ watched: [Row], _ pane: Pane, isOn: Bool) -> String {
        if pane == .running {
            return isOn
                ? "Stops every watched app, its helpers, and everything they started, such as an agent's shells and tools. The switches stay as they are."
                : "No watched apps are running. Switch an app's Running switch on to open it."
        }
        if pane == .links {
            return isOn
                ? "Switches Links off for every watched app, so Revoke asks you before links or files open them."
                : "Revoke asks you before links or files open any watched app. Switch on to let them open directly."
        }
        if pane == .localNetwork && filter.isOn {
            if isOn {
                return "Blocks every watched app from reaching your local network."
            }
            return watched.contains(where: \.isBlockedFromLocalNetwork)
                ? "Revoke is keeping watched apps off your local network. Switch on to stop blocking them."
                : "Off in System Settings. Switching it on opens it."
        }
        return isOn
            ? "Switches \(pane.title) off for every watched app."
            : "Off for every watched app. Switching it on opens System Settings."
    }

    private func help(_ row: Row, _ pane: Pane) -> String {
        if pane == .running {
            return row.isRunning
                ? "\(row.name) is running. Switch off to stop it, its helpers, and everything they started, such as an agent's shells and tools."
                : "\(row.name) isn't running. Switch on to open it."
        }
        if pane == .links, let links = model.snapshot.links[row.client] {
            let open = Self.ways(links.open)
            let confirm = links.open.contains(where: \.isFile)
                ? " macOS asks you to confirm each file type." : ""
            if links.guarded.isEmpty {
                return "Web pages, documents, and other apps can open \(row.name) with \(open), which can carry instructions for it. Switch off to have Revoke ask you first, every time.\(confirm)"
            }
            let guarded = Self.ways(links.guarded)
            if links.open.isEmpty {
                return "Revoke asks you before \(guarded) open \(row.name), and shows what they carry. Switch on to let them open it directly."
            }
            return "Revoke asks you before \(guarded) open \(row.name), but \(open) still open it directly. Switch off to have Revoke ask about those too.\(confirm)"
        }
        if pane == .localNetwork && filter.isOn {
            if row.isBlockedFromLocalNetwork {
                return "Revoke is keeping \(row.name) off your local network. Switch on to stop blocking it."
            }
            return row.isAllowed(pane)
                ? "\(row.name) can reach your local network. Switch off to block it."
                : "Off in System Settings. Switching it on opens it."
        }
        guard row.isAllowed(pane) else {
            return "Off. Switching it on opens System Settings."
        }
        if pane.tccutilServices.isEmpty || row.client.bundleID == nil {
            return "\(row.name) has \(pane.title). Only System Settings can change this, so switching it off opens it."
        }
        return "\(row.name) has \(pane.title). Switch off to revoke."
    }

    /// "claude:// links and .skill files".
    private static func ways(_ links: [Link]) -> String {
        let schemes = links.filter { !$0.isFile }.map(\.description)
        let files = Array(Set(links.filter(\.isFile).map(\.description))).sorted()
        var parts: [String] = []
        if !schemes.isEmpty { parts.append("\(schemes.formatted(.list(type: .and))) links") }
        if !files.isEmpty { parts.append("\(files.formatted(.list(type: .and))) files") }
        return parts.joined(separator: " and ")
    }
}

/// A switch that is orange while access is on, whether or not the panel has focus.
/// System switches turn gray in a window that isn't key, which made on and off hard
/// to tell apart at a glance.
struct AccessSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? AnyShapeStyle(.orange) : AnyShapeStyle(.quaternary))
                .frame(width: 30, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Capsule buttons drawn to match AccessSwitchStyle, so the panel looks the same
/// whether or not it has focus.
struct PanelButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominent ? .body.weight(.medium) : .callout)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, prominent ? 14 : 10)
            .padding(.vertical, prominent ? 6 : 4)
            .background(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
