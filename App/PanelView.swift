import SwiftUI

/// The popover under the menu bar icon: one switch per app and privacy list.
struct PanelView: View {
    @ObservedObject var model: AccessModel
    @ObservedObject var settings: Settings
    @ObservedObject var filter: NetworkFilter
    let openSettings: () -> Void

    /// Width of each privacy list's column, shared by the titles and the rows so
    /// they line up even though the rows scroll.
    private static let columnWidth: CGFloat = 76
    private static let columnSpacing: CGFloat = 6
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
                if model.isRevoking { ProgressView().controlSize(.small) }
            }
            if let activity = model.lastActivity {
                Text("\(activity.date.formatted(date: .omitted, time: .shortened)) · \(activity.text)")
                    .font(.caption)
                    .foregroundStyle(activity.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Switching access on opens System Settings, because macOS only lets you grant it there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 460)
    }

    /// The titles sit outside the list so they stay put while it scrolls.
    private var columnTitles: some View {
        HStack(spacing: Self.columnSpacing) {
            Spacer()
            ForEach(Pane.allCases) { pane in
                VStack(spacing: 3) {
                    Image(systemName: pane.symbol)
                    Text(pane.shortTitle).font(.caption2).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .frame(width: Self.columnWidth)
                .help(pane.title)
            }
        }
    }

    private func appList(watched: [Row], others: [Row], leftovers: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Watched")
            if watched.isEmpty {
                Text("No watched apps are in these lists.").foregroundStyle(.secondary)
            }
            ForEach(watched) { row($0) }

            if !others.isEmpty {
                sectionTitle("Other apps with access").padding(.top, 6)
                ForEach(others) { row($0) }
            }

            if !leftovers.isEmpty {
                HStack {
                    sectionTitle("Deleted apps")
                    Spacer()
                    Button("Remove All") { model.removeLeftovers() }
                        .buttonStyle(PanelButtonStyle(prominent: false))
                        .disabled(model.isRevoking)
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
            }
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
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

    private func row(_ row: Row) -> some View {
        HStack(spacing: Self.columnSpacing) {
            label(row, caption: row.deadline.map {
                "Revokes at \($0.formatted(date: .omitted, time: .shortened))"
            })
            ForEach(Pane.allCases) { pane in
                cell(row, pane).frame(width: Self.columnWidth)
            }
        }
    }

    /// A deleted app gets one button rather than switches: nothing it left behind
    /// is worth keeping, and none of it can be switched back on.
    private func leftoverRow(_ row: Row) -> some View {
        let on = Pane.allCases.filter(row.isAllowed).map(\.shortTitle)
        return HStack(spacing: Self.columnSpacing) {
            label(row, caption: on.isEmpty ? "Listed, switched off" : "\(on.formatted(.list(type: .and))) on")
            Button("Remove") { model.removeLeftovers([row.client]) }
                .buttonStyle(PanelButtonStyle(prominent: false))
                .disabled(model.isRevoking)
                .frame(width: Self.columnWidth)
                .help("Remove \(row.client.key) from the privacy lists.")
        }
    }

    private func label(_ row: Row, caption: String?) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: row.icon)
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .help(row.client.key)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cell(_ row: Row, _ pane: Pane) -> some View {
        if pane.tccService != nil && !model.snapshot.canReadTCC {
            Image(systemName: "questionmark")
                .foregroundStyle(.tertiary)
                .help("Revoke needs Full Disk Access to see this.")
        } else {
            Toggle(pane.title, isOn: Binding(
                get: { row.isAllowed(pane) },
                set: { model.set(pane, on: $0, for: row.client) }))
                .toggleStyle(AccessSwitchStyle())
                .disabled(model.isRevoking)
                .help(help(row, pane))
        }
    }

    private func help(_ row: Row, _ pane: Pane) -> String {
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
