import AppKit
import SwiftUI

extension View {
    /// A tooltip that shows whether or not Revoke is the active app. macOS draws
    /// `.help` tooltips only in the active app's windows, and the menu bar panel
    /// often opens without Revoke becoming active, so they never appeared there.
    func tip(_ text: String) -> some View {
        modifier(TipModifier(text: text))
    }

    /// Draws the tips inside this view instead of in a window of their own. The
    /// menu bar panel needs this: another window in front of it changed how macOS
    /// drew the panel's glass.
    func tipHost() -> some View {
        modifier(TipHost())
    }
}

extension EnvironmentValues {
    @Entry fileprivate var tipState: TipState?
}

private struct TipModifier: ViewModifier {
    let text: String
    @Environment(\.tipState) private var host
    @State private var id = UUID()
    /// Where this view is in the host, so the tip can sit just below it.
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        content
            .accessibilityHint(text)
            .background {
                if host != nil {
                    GeometryReader { proxy in
                        let current = proxy.frame(in: .named(TipHost.space))
                        Color.clear
                            .onAppear { frame = current }
                            .onChange(of: current) { _, new in frame = new }
                    }
                }
            }
            .onHover { hovering in
                if let host {
                    host.hover(text, id: id, below: frame, isHovering: hovering)
                } else {
                    Tooltip.shared.hover(text, id: id, isHovering: hovering)
                }
            }
            .onDisappear {
                host?.end(id)
                Tooltip.shared.end(id)
            }
    }
}

/// The tip a host is showing, and the wait before it shows.
@MainActor
private final class TipState: ObservableObject {
    struct Tip {
        let text: String
        let anchor: CGRect
    }

    @Published private(set) var current: Tip?
    private var owner: UUID?
    private var pending: Task<Void, Never>?

    func hover(_ text: String, id: UUID, below anchor: CGRect, isHovering: Bool) {
        guard isHovering else { return end(id) }
        owner = id
        pending?.cancel()
        // Moving from one tip to the next shows the next straight away.
        let delay: Duration = current == nil ? .milliseconds(600) : .zero
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.owner == id else { return }
            self.current = Tip(text: text, anchor: anchor)
        }
    }

    func end(_ id: UUID) {
        if owner == id { hide() }
    }

    func hide() {
        owner = nil
        pending?.cancel()
        current = nil
    }
}

private struct TipHost: ViewModifier {
    static let space = "tips"
    @StateObject private var tips = TipState()

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(Self.space))
            .environment(\.tipState, tips)
            .overlay {
                if let tip = tips.current {
                    TipLayout(anchor: tip.anchor) { TipBubble(text: tip.text) }
                        .allowsHitTesting(false)
                }
            }
            // Like system tooltips, a click or closing the panel puts the tip away.
            .simultaneousGesture(TapGesture().onEnded { tips.hide() })
            .onReceive(NotificationCenter.default.publisher(for: NSPopover.willCloseNotification)) { _ in
                tips.hide()
            }
    }
}

/// Puts the tip just below the view it describes, so it never covers it, and
/// above instead when there's no room below. It stays inside the host.
private struct TipLayout: Layout {
    let anchor: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tip = subviews.first else { return }
        let margin: CGFloat = 6
        let size = tip.sizeThatFits(ProposedViewSize(width: min(280, bounds.width - margin * 2), height: nil))
        let x = min(max(anchor.midX - size.width / 2, margin), bounds.width - size.width - margin)
        var y = anchor.maxY + 4
        if y + size.height > bounds.height - margin { y = anchor.minY - size.height - 4 }
        tip.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
    }
}

private struct TipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: NSFont.smallSystemFontSize))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}

/// One floating label for tips outside a `tipHost`, such as in Settings, drawn in
/// its own window so the window's edges don't clip it.
@MainActor
final class Tooltip {
    static let shared = Tooltip()

    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    /// The view the pointer is over, and the wait before its tip shows.
    private var owner: UUID?
    private var pending: Task<Void, Never>?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        // Above the menu bar panel, and never in the way of the pointer.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 280
        // A solid background rather than a material: on macOS 27 the tooltip material
        // is Liquid Glass, and it smeared the panel's own glass under the tip.
        let background = TipBackground()
        background.addSubview(label)
        panel.contentView = background

        // Like system tooltips, a click puts the tip away.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated { Tooltip.shared.hide() }
            return event
        }
    }

    func hover(_ text: String, id: UUID, isHovering: Bool) {
        guard isHovering else { return end(id) }
        owner = id
        pending?.cancel()
        // Moving from one tip to the next shows the next straight away.
        let delay: Duration = panel.isVisible ? .zero : .milliseconds(600)
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.owner == id else { return }
            self.show(text)
        }
    }

    func end(_ id: UUID) {
        if owner == id { hide() }
    }

    func hide() {
        owner = nil
        pending?.cancel()
        panel.orderOut(nil)
    }

    private func show(_ text: String) {
        label.stringValue = text
        let padding = NSSize(width: 8, height: 5)
        let size = label.fittingSize
        label.frame = NSRect(origin: NSPoint(x: padding.width, y: padding.height), size: size)
        let frameSize = NSSize(width: size.width + padding.width * 2, height: size.height + padding.height * 2)

        // Below and right of the pointer, kept on the screen it's on.
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 4, y: mouse.y - 22 - frameSize.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - frameSize.width)
            if origin.y < visible.minY { origin.y = mouse.y + 16 }
        }
        panel.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        panel.orderFrontRegardless()
    }
}

/// A rounded, solid tip background that follows light and dark mode.
private final class TipBackground: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
