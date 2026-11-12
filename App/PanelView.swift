import SwiftUI

/// The popover under the menu bar icon: one switch per app and privacy list.
struct PanelView: View {
    @ObservedObject var model: AccessModel
    @ObservedObject var settings: Settings
    @ObservedObject var filter: NetworkFilter
    /// Set from the screen the panel opens on: see PanelLayout.width(forScreenWidth:).
    var width: CGFloat = PanelLayout.preferredWidth
    /// The tallest the panel may be on the screen it opens on. Past that it scrolls.
    var maxHeight: CGFloat = .infinity
    let openSettings: () -> Void

    /// Past this many rows the list scrolls, so the panel stays on screen.
    private static let rowsBeforeScrolling = 10

    var body: some View {
        // On a screen too short for everything, the whole panel scrolls rather than
        // macOS pushing its top, with the title and Settings, off the screen.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        // A solid ground. A popover is see-through by default, and over a dark desktop
        // in the light appearance it went mid-gray, with the app names gray on gray.
        .background(Color(nsColor: .windowBackgroundColor))
        .tipHost()
    }

    private var content: some View {
        let watched = model.rows(watched: true)
        let others = model.rows(watched: false)
        let leftovers = model.leftoverRows
        return VStack(alignment: .leading, spacing: 14) {
            header
            if !model.snapshot.canReadTCC { fullDiskAccessNotice }
            onForNow

            VStack(alignment: .leading, spacing: 6) {
                groupTitles
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
                    .foregroundStyle(activity.isError ? Color.panelError : Color.panelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .tip(activity.isError ? "The last thing Revoke tried failed." : "The last thing Revoke did.")
            }
            key
        }
        .padding(PanelLayout.padding)
    }

    /// Which columns behave alike, named above them: what only macOS can grant, what
    /// Revoke keeps itself and switches both ways, and what only ever takes away.
    private var groupTitles: some View {
        HStack(alignment: .bottom, spacing: PanelLayout.columnSpacing) {
            Spacer()
            ForEach(PanelLayout.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title).font(.caption.weight(.semibold))
                    Text(group.note).font(.caption2).foregroundStyle(Color.panelSecondary)
                        .tip(group.tip)
                    Rectangle().fill(.separator).frame(height: 1).padding(.top, 2)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: PanelLayout.width(ofColumns: group.columns), alignment: .leading)
                .opacity(group.title.isEmpty ? 0 : 1)
                .accessibilityElement(children: .combine)
                .accessibilityHidden(group.title.isEmpty)
            }
        }
    }

    /// The titles sit outside the list so they stay put while it scrolls.
    private var columnTitles: some View {
        HStack(spacing: PanelLayout.columnSpacing) {
            Spacer()
            ForEach(Pane.allCases) { pane in
                columnTitle(symbol: pane.symbol, title: pane.shortTitle, tip: pane.explanation)
            }
            columnTitle(
                symbol: "arrow.uturn.backward", title: "Revoke",
                tip: "Revoke: switches off every access switch the app has, Links included, and resets Other. Running stays as it is.")
        }
    }

    // MARK: - On for now

    private struct Allowance: Identifiable {
        let client: Client
        let pane: Pane
        let until: Date
        var id: String { "\(pane.title) \(client.key)" }
    }

    /// Everything that's on only for now, soonest to end first.
    private var allowanceList: [Allowance] {
        let now = model.clock
        let local = model.allowances.localNetwork.map { Allowance(client: .bundle($0.key), pane: .localNetwork, until: $0.value) }
        let internet = model.allowances.internet.map { Allowance(client: .bundle($0.key), pane: .internet, until: $0.value) }
        return (local + internet).filter { $0.until > now }.sorted { ($0.until, $0.id) < ($1.until, $1.id) }
    }

    /// Access given for a while sits at the top, where the eye lands, with when it
    /// ends and a way to end it now. With nothing on for now, it isn't there.
    @ViewBuilder
    private var onForNow: some View {
        let list = allowanceList
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("On for now")
                    .tip("Access you said yes to when an app asked. Revoke takes each one back by itself when its time is up.")
                VStack(spacing: 0) {
                    ForEach(list) { item in
                        if item.id != list.first?.id { Divider() }
                        allowanceRow(item)
                    }
                }
                .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func allowanceRow(_ item: Allowance) -> some View {
        let name = AppInfo.name(item.client)
        let minutes = Allowances.minutesLeft(until: item.until, now: model.clock)
        let end = item.until.formatted(date: .omitted, time: .shortened)
        return HStack(spacing: 10) {
            Image(nsImage: AppInfo.icon(item.client))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(name) · \(item.pane.title)").fontWeight(.medium)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(Image(systemName: "clock")) Until \(end) · \(Allowances.spoken(minutes: minutes)) left. \(afterward(item))")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), \(item.pane.title), on for now. Until \(end), \(Allowances.spoken(minutes: minutes)) left. \(afterward(item))")
            Button("End Now") { model.endAllowance(item.pane, for: item.client) }
                .buttonStyle(PanelButtonStyle(prominent: false))
                .disabled(model.isRevoking)
                .fixedSize()
                .accessibilityLabel("End \(item.pane.title) for \(name) now")
                .tip("Takes \(item.pane.title) back from \(name) now, without waiting for \(end).")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// What Revoke does when the time is up.
    private func afterward(_ item: Allowance) -> String {
        if item.pane == .localNetwork { return "Then Revoke blocks it from your local network again." }
        // The hosts are in the switch's tooltip; a list of them here ran to two lines.
        return model.internetHosts(for: item.client).isEmpty ? "Then Revoke keeps it off the internet again."
            : "Then Revoke keeps it to its model's hosts again."
    }

    /// What a cell's switch shows beyond on and off.
    private func switchKind(_ row: Row, _ pane: Pane) -> AccessSwitchStyle.Kind {
        guard row.isAllowed(pane) else { return .plain }
        if let until = row.allowedUntil(pane), until > model.clock {
            return .timed(Allowances.compact(minutes: Allowances.minutesLeft(until: until, now: model.clock)))
        }
        // On, and Revoke can't take it back: only System Settings can.
        let isPrivacy = pane.tccService != nil
        if isPrivacy && (pane.tccutilServices.isEmpty || row.client.bundleID == nil) { return .locked }
        return .plain
    }

    // MARK: - The key

    /// One line saying what each shape of switch means.
    private var key: some View {
        let items: [(AnyView, String)] = [
            (AnyView(AccessSwitch(isOn: false, kind: .plain)), "Off"),
            (AnyView(AccessSwitch(isOn: true, kind: .plain)), "On"),
            (AnyView(AccessSwitch(isOn: true, kind: .timed("38m"))), "On for now"),
            (AnyView(AccessSwitch(isOn: true, kind: .locked)), "Only System Settings can change"),
            (AnyView(AccessSwitch(isOn: true, kind: .mixed)), "On for some"),
            (AnyView(Image(systemName: "questionmark").foregroundStyle(Color.panelSecondary)), "Unknown"),
            (AnyView(Text("–").foregroundStyle(Color.panelSecondary)), "Doesn't apply"),
        ]
        func line(_ range: Range<Int>) -> some View {
            HStack(spacing: 10) {
                ForEach(range, id: \.self) { index in
                    HStack(spacing: 4) {
                        items[index].0.scaleEffect(0.8).accessibilityHidden(true)
                        Text(items[index].1)
                    }
                }
            }
        }
        return ViewThatFits(in: .horizontal) {
            line(0..<items.count)
            VStack(alignment: .leading, spacing: 4) {
                line(0..<4)
                line(4..<items.count)
            }
        }
        .font(.caption2)
        .foregroundStyle(Color.panelSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Key: \(items.map(\.1).joined(separator: "; "))")
    }

    private func columnTitle(symbol: String, title: String, tip: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
            Text(title).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.panelSecondary)
        .frame(width: PanelLayout.columnWidth, alignment: .top)
        .tip(tip)
    }

    private func appList(watched: [Row], others: [Row], leftovers: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            watchedHeader(watched)
            if watched.isEmpty {
                Text("No watched apps are installed or running.").foregroundStyle(Color.panelSecondary)
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
                    .foregroundStyle(Color.panelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(leftovers) { leftoverRow($0) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Revoke").font(.headline)
                Text(model.statusText).font(.subheadline).foregroundStyle(Color.panelSecondary)
                    .tip(lockHelp)
            }
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.panelSecondary)
            .tip("Settings")
            .accessibilityLabel("Settings")
        }
    }

    /// What the menu bar lock is showing, and why.
    private var lockHelp: String {
        if !model.snapshot.canReadTCC {
            return "Revoke can't read the permissions list without Full Disk Access, so the lock shows a warning."
        }
        if settings.lockFollowsRunningOnly {
            return model.lockIsOpen
                ? "The lock is open while a watched app is running."
                : "The lock is closed: no watched app is running. Access left on is listed above, and a watched app gets it back when it starts."
        }
        return model.lockIsOpen
            ? "The lock is open while a watched app is running or has Device Control, Screen Recording, or Input Monitoring."
            : "The lock is closed: no watched app is running or has Device Control, Screen Recording, or Input Monitoring."
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
            .foregroundStyle(Color.panelSecondary)
    }

    /// One row for every watched app at once. It's shaded and says how many apps it
    /// covers, so it doesn't read as one more app; under a switch that's on for some
    /// apps and off for others, it says for how many.
    private func watchedHeader(_ watched: [Row]) -> some View {
        HStack(spacing: PanelLayout.columnSpacing) {
            VStack(alignment: .leading, spacing: 0) {
                Text(watched.isEmpty ? "Watched" : "All watched apps").font(.callout.weight(.semibold))
                if !watched.isEmpty {
                    Text(watched.count == 1 ? "Switches act on the one app" : "Switches act on all \(watched.count)")
                        .font(.caption2).foregroundStyle(Color.panelSecondary)
                }
            }
            .tip("Apps Revoke looks after: Revoke All Watched and the automatic options cover them. Right-click one to stop it or stop watching it, or choose in Settings.")
            .frame(maxWidth: .infinity, alignment: .leading)
            if !watched.isEmpty {
                ForEach(Pane.allCases) { pane in
                    VStack(spacing: 1) {
                        watchedCell(watched, pane)
                        Text(watchedCount(watched, pane).flatMap { $0.on > 0 && $0.on < $0.total ? "\($0.on) of \($0.total)" : nil } ?? " ")
                            .font(.caption2).foregroundStyle(Color.panelSecondary).lineLimit(1)
                            .accessibilityHidden(true)
                    }
                    .frame(width: PanelLayout.columnWidth)
                }
                VStack(spacing: 1) {
                    watchedAllAccessCell(watched)
                    Text(" ").font(.caption2).accessibilityHidden(true)
                }
                .frame(width: PanelLayout.columnWidth)
            }
        }
        .padding(.vertical, 5)
        // The shading reaches a little past the row without moving its columns.
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)).padding(.horizontal, -6))
    }

    /// How many watched apps have a column's switch on, of those it applies to, or nil
    /// for a column with no switch to count.
    private func watchedCount(_ watched: [Row], _ pane: Pane) -> (on: Int, total: Int)? {
        guard pane != .other, model.snapshot.canRead(pane), pane != .internet || filter.isOn else { return nil }
        let rows = watched.filter { row in
            if pane == .links { return model.snapshot.links[row.client] != nil }
            return pane == .localNetwork || row.client.bundleID != nil
        }
        return rows.isEmpty ? nil : (rows.filter { $0.isAllowed(pane) }.count, rows.count)
    }

    private func row(_ row: Row) -> some View {
        HStack(spacing: PanelLayout.columnSpacing) {
            label(row, caption: ([
                AppInfo.role(row.client),
                row.deadline.map { "Revokes at \($0.formatted(date: .omitted, time: .shortened))" },
            ] + [Pane.localNetwork, .internet].map { pane in
                row.allowedUntil(pane).flatMap { $0 > model.clock ? "\(pane.title) until \($0.formatted(date: .omitted, time: .shortened))" : nil }
            }).compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
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
        let on = Pane.allCases.filter { $0 != .internet && row.isAllowed($0) }.map(\.shortTitle)
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
                    Text(caption).font(.caption2).foregroundStyle(Color.panelSecondary)
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
                .foregroundStyle(Color.panelSecondary)
                .tip("Nothing opens \(row.name) with a link or a file.")
        } else if pane == .internet && !filter.isOn {
            Text("–")
                .foregroundStyle(Color.panelSecondary)
                .tip("Install Revoke's network filter in Settings to keep an app to its model's hosts.")
        } else if (pane == .running || pane == .other || pane == .internet) && row.client.bundleID == nil {
            Text("–")
                .foregroundStyle(Color.panelSecondary)
                .tip("Only System Settings can change command-line tools listed by path.")
        } else if pane == .other {
            otherMenu(row)
        } else if !model.snapshot.canRead(pane) {
            Image(systemName: "questionmark")
                .foregroundStyle(Color.panelSecondary)
                .tip("Revoke needs Full Disk Access to see this.")
        } else {
            let kind = switchKind(row, pane)
            Toggle("\(pane.title) for \(row.name)", isOn: Binding(
                get: { row.isAllowed(pane) },
                set: { model.set(pane, on: $0, for: row.client) }))
                .toggleStyle(AccessSwitchStyle(kind: kind))
                .accessibilityValue(spokenValue(row, pane, kind))
                .disabled(model.isRevoking)
                .tip(help(row, pane))
        }
    }

    @ViewBuilder
    private func watchedCell(_ watched: [Row], _ pane: Pane) -> some View {
        if pane == .links && watched.allSatisfy({ model.snapshot.links[$0.client] == nil }) {
            Text("–")
                .foregroundStyle(Color.panelSecondary)
                .tip("No watched app registers links or files.")
        } else if pane == .internet && !filter.isOn {
            Text("–")
                .foregroundStyle(Color.panelSecondary)
                .tip("Install Revoke's network filter in Settings to keep apps to their models' hosts.")
        } else if pane == .other {
            watchedOtherMenu(watched)
        } else if !model.snapshot.canRead(pane) {
            Image(systemName: "questionmark")
                .foregroundStyle(Color.panelSecondary)
                .tip("Revoke needs Full Disk Access to see this.")
        } else {
            let isOn = watched.contains { row in
                (pane == .localNetwork || row.client.bundleID != nil) && row.isAllowed(pane)
            }
            let count = watchedCount(watched, pane)
            let isMixed = count.map { $0.on > 0 && $0.on < $0.total } ?? false
            Toggle("\(pane.title) for all watched apps", isOn: Binding(
                get: { isOn },
                set: { model.set(pane, on: $0, forWatched: watched) }))
                .toggleStyle(AccessSwitchStyle(kind: isMixed ? .mixed : .plain))
                .accessibilityValue(count.map { isMixed ? "On for \($0.on) of \($0.total) apps" : isOn ? "On" : "Off" } ?? "")
                .disabled(model.isRevoking)
                .tip(watchedHelp(watched, pane, isOn: isOn))
        }
    }

    @ViewBuilder
    private func watchedAllAccessCell(_ watched: [Row]) -> some View {
        let isOn = watched.contains { $0.hasAccess(filterIsOn: filter.isOn) }
        if !isOn && !model.snapshot.canReadTCC {
            Image(systemName: "questionmark")
                .foregroundStyle(Color.panelSecondary)
                .tip("Revoke needs Full Disk Access to see this.")
        } else {
            // A button, not a switch: it only ever takes access away.
            Button("Revoke") { model.revokeWatched(reason: nil) }
                .buttonStyle(PanelButtonStyle(prominent: false, compact: true))
                .disabled(model.isRevoking || !isOn)
                .accessibilityLabel("Revoke all access for all watched apps")
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
                .foregroundStyle(Color.panelSecondary)
                .tip("Only System Settings can change command-line tools listed by path.")
        } else if !isOn && !model.snapshot.canReadTCC {
            Image(systemName: "questionmark")
                .foregroundStyle(Color.panelSecondary)
                .tip("Revoke needs Full Disk Access to see this.")
        } else {
            Button("Revoke") { model.revoke([row.client], panes: Pane.access, reason: nil) }
                .buttonStyle(PanelButtonStyle(prominent: false, compact: true))
                .disabled(model.isRevoking || !isOn)
                .accessibilityLabel("Revoke all access for \(row.name)")
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
        if pane == .internet {
            return isOn
                ? "Keeps every watched app to its own model provider's hosts on the internet, and the ones you added in Settings."
                : "Revoke is keeping every watched app to its model's hosts. Switch on to give them the whole internet again."
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

    /// What VoiceOver says a switch's value is, where "on" alone would mislead.
    private func spokenValue(_ row: Row, _ pane: Pane, _ kind: AccessSwitchStyle.Kind) -> String {
        switch kind {
        case .timed:
            guard let until = row.allowedUntil(pane) else { return "On" }
            let left = Allowances.spoken(minutes: Allowances.minutesLeft(until: until, now: model.clock))
            return "On for now, until \(until.formatted(date: .omitted, time: .shortened)), \(left) left. Switch off to end it now."
        case .locked: return "On. Only System Settings can change it."
        case .plain, .mixed: return row.isAllowed(pane) ? "On" : "Off"
        }
    }

    private func help(_ row: Row, _ pane: Pane) -> String {
        if let until = row.allowedUntil(pane), until > model.clock, row.isAllowed(pane) {
            let left = Allowances.spoken(minutes: Allowances.minutesLeft(until: until, now: model.clock))
            let then = pane == .localNetwork ? "blocks it again" : "keeps it to its model's hosts again"
            return "\(row.name) has \(pane.title) until \(until.formatted(date: .omitted, time: .shortened)), \(left) from now, because you said yes when it asked. Then Revoke \(then). Switch off to end it now."
        }
        if pane == .running {
            return row.isRunning
                ? "\(row.name) is running. Switch off to stop it, its helpers, and everything they started, such as an agent's shells and tools."
                : "\(row.name) isn't running. Switch on to open it."
        }
        if pane == .internet {
            let hosts = model.internetHosts(for: row.client)
            let kept = hosts.isEmpty ? "off the internet altogether, until you add its model's hosts in Settings"
                : "to \(hosts.formatted(.list(type: .and))) on the internet"
            return row.isInternetLimited
                ? "Revoke is keeping \(row.name), and the commands it starts, \(kept). Switch on to give it the whole internet again."
                : "\(row.name) can reach anywhere on the internet. Switch off to keep it, and the commands it starts, \(kept). Your local network has its own switch."
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
    /// What a switch shows beyond on and off. None of these is told apart by color alone.
    enum Kind: Equatable {
        case plain
        /// On for some of the apps a switch covers: the knob sits in the middle.
        case mixed
        /// On, and only System Settings can change it: a lock on the knob.
        case locked
        /// On for now: a clock and the time left, in place of the knob.
        case timed(String)
    }

    var kind: Kind = .plain

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            AccessSwitch(isOn: configuration.isOn, kind: kind)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// How a switch is drawn, shared by the switches and the key that explains them.
struct AccessSwitch: View {
    let isOn: Bool
    let kind: AccessSwitchStyle.Kind

    var body: some View {
        if case .timed(let left) = kind, isOn {
            HStack(spacing: 2) {
                Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
                Text(left).font(.system(size: 10, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(.primary)
            .frame(width: 46, height: 18)
            .background(Color.orange.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(.orange, lineWidth: 1.5))
            .contentShape(Capsule())
        } else {
            Capsule()
                .fill(isOn ? Color.orange : Color.panelTrack)
                .frame(width: 30, height: 18)
                .overlay(alignment: kind == .mixed && isOn ? .center : isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                        .overlay {
                            if kind == .mixed && isOn {
                                Image(systemName: "minus").font(.system(size: 8, weight: .heavy))
                                    .foregroundStyle(.black.opacity(0.75))
                            } else if kind == .locked && isOn {
                                Image(systemName: "lock.fill").font(.system(size: 7))
                                    .foregroundStyle(.black.opacity(0.75))
                            }
                        }
                        .padding(2)
                }
                .contentShape(Capsule())
        }
    }
}

/// Capsule buttons drawn to match AccessSwitchStyle, so the panel looks the same
/// whether or not it has focus.
struct PanelButtonStyle: ButtonStyle {
    let prominent: Bool
    /// Small enough to sit in a column of the grid.
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominent ? .body.weight(.medium) : compact ? .caption : .callout)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, prominent ? 14 : compact ? 7 : 10)
            .padding(.vertical, prominent ? 6 : compact ? 3 : 4)
            .background(prominent ? Color.panelProminent : Color.panelTrack.opacity(0.6), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The panel's own colors, measured against its background rather than left to the
/// system's, which came out under 4.5:1 for small gray text and for white on the tint.
extension Color {
    private static func panel(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }

    /// Captions, column titles, and notes: 6.5:1 on the light panel, 8:1 on the dark.
    static let panelSecondary = panel(light: 0.37, dark: 0.72)
    /// A switch that's off, and the plain buttons.
    static let panelTrack = panel(light: 0.74, dark: 0.32)
    /// The one filled button. White on the system's blue is about 4:1; on this, 5.4:1.
    static let panelProminent = Color(red: 0, green: 0.39, blue: 0.85)
    /// Something failed: a red dark enough to read on white, light enough on black.
    static let panelError = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 1, green: 0.45, blue: 0.40, alpha: 1) : NSColor(red: 0.75, green: 0.09, blue: 0.05, alpha: 1)
    })
}
