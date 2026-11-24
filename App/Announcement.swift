import AppKit

/// Says a line through VoiceOver, for a change that shows on screen without the
/// keyboard's focus moving to it: the panel's activity line, or a window that opens
/// beside another app's.
@MainActor
enum Announcement {
    /// `isUrgent` speaks over whatever VoiceOver is saying, for a failure or for
    /// something the person has to act on now.
    static func post(_ text: String, isUrgent: Bool = false) {
        // There's no app when the tests run the model by itself.
        guard let app = NSApp else { return }
        // VoiceOver takes announcements from a window. The panel is a popover, which
        // is key but never main, so the key window comes first.
        let element: Any = app.keyWindow ?? app.mainWindow ?? app
        let priority: NSAccessibilityPriorityLevel = isUrgent ? .high : .medium
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: priority.rawValue,
        ])
    }
}
