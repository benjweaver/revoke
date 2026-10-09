import AppKit
import SwiftUI

extension View {
    /// A tooltip that shows whether or not Revoke is the active app. macOS draws
    /// `.help` tooltips only in the active app's windows, and the menu bar panel
    /// often opens without Revoke becoming active, so they never appeared there.
    func tip(_ text: String) -> some View {
        modifier(TipModifier(text: text))
    }
}

private struct TipModifier: ViewModifier {
    let text: String
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .accessibilityHint(text)
            .onHover { Tooltip.shared.hover(text, id: id, isHovering: $0) }
            .onDisappear { Tooltip.shared.end(id) }
    }
}

/// One floating label shared by every `.tip`, drawn in its own window so the
/// panel's edges don't clip it.
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
