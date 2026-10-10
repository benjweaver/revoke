import Foundation
import Testing

/// The columns, how entries from the privacy database add up to one switch, and what an
/// app can ask for that Revoke can't see.
struct PaneTests {
    @Test func everyAccessColumnCanBeRevoked() {
        for pane in Pane.access {
            // Each is a TCC service tccutil can reset, or one of Revoke's own.
            #expect(!pane.tccutilServices.isEmpty || [.localNetwork, .links].contains(pane), "\(pane)")
        }
        #expect(!Pane.access.contains(.running))
        #expect(Pane.other.tccService == nil)
        #expect(Set(Pane.other.tccutilServices) == Set(OtherAccess.allCases.flatMap(\.tccutilServices)))
        #expect(Pane.other.tccutilServices.contains("AppleEvents"))
    }

    @Test func anAllowedEntryWinsAndCountsFromTheEarliest() {
        let early = Date(timeIntervalSince1970: 1000)
        let late = Date(timeIntervalSince1970: 2000)
        let claude = Client.bundle("com.anthropic.claudefordesktop")
        var snapshot = Snapshot()
        snapshot.add(Entry(access: .denied, since: early), for: claude, .deviceControl)
        snapshot.add(Entry(access: .allowed, since: late), for: claude, .deviceControl)
        snapshot.add(Entry(access: .allowed, since: early), for: claude, .deviceControl)
        snapshot.add(Entry(access: .denied, since: late), for: claude, .deviceControl)
        #expect(snapshot.entries[claude]?[.deviceControl] == Entry(access: .allowed, since: early))
    }

    @Test func onlyTCCColumnsNeedFullDiskAccess() {
        let snapshot = Snapshot()
        #expect(!snapshot.canRead(.deviceControl) && !snapshot.canRead(.inputMonitoring))
        #expect(snapshot.canRead(.running) && snapshot.canRead(.links) && snapshot.canRead(.other))
    }

    /// What Claude, ChatGPT and Claude Code declared on macOS 27 in October 2026.
    @Test func readsWhatAnAppCanAskFor() {
        let claude = OtherAccess.askable(
            info: ["NSAppleEventsUsageDescription": "", "NSCameraUsageDescription": "", "NSMicrophoneUsageDescription": "",
                   "NSDesktopFolderUsageDescription": ""],
            entitlements: ["com.apple.security.personal-information.photos-library": true])
        #expect(claude == [.automation, .camera, .microphone, .files, .appManagement, .personalData])
        let claudeCode = OtherAccess.askable(
            info: ["NSAppleEventsUsageDescription": "", "NSMicrophoneUsageDescription": ""],
            entitlements: ["com.apple.security.automation.apple-events": true])
        #expect(claudeCode == [.automation, .microphone, .files, .appManagement])
        // Any app can ask for files and folders, and for App Management.
        #expect(OtherAccess.askable(info: [:], entitlements: [:]) == [.files, .appManagement])
    }
}
