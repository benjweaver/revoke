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

    @Test func codingAgentsAreWatchedWhateverTheirBundleIDLooksLike() {
        // Cursor ships under a ToDesktop ID; Grok Bot is made by Anysphere.
        // DeepSeek's current app is com.deepseek.dsh; older builds were com.deepseek.harness.
        for id in ["com.todesktop.230313mzl4w4u92", "com.anysphere.sand", "com.microsoft.VSCode", "com.openai.codex",
                   "dev.zed.Zed", "dev.zed.Zed-Preview", "dev.kiro.desktop", "com.trae.app", "cn.trae.app",
                   "com.google.antigravity", "com.google.antigravity-ide", "com.exafunction.windsurf",
                   "com.deepseek.dsh", "com.deepseek.harness", "com.tencent.codebuddy", "com.tencent.codebuddycn",
                   "ai.factory.desktop", "com.electron.factory"] {
            #expect(Client.bundle(id).vendor.map(Client.watchedVendors.contains) == true, "\(id)")
        }
        // Helpers belong to the app. Other apps from the same shared prefix do not.
        #expect(Client.bundle("com.todesktop.230313mzl4w4u92.helper").vendor == "com.todesktop.230313mzl4w4u92")
        #expect(Client.bundle("com.google.antigravity.helper.GPU").vendor == "com.google.antigravity")
        #expect(Client.bundle("com.microsoft.VSCode.helper").vendor == "com.microsoft.vscode")
        #expect(Client.bundle("com.deepseek.dsh").vendor == Client.bundle("com.deepseek.harness").vendor)
        #expect(Client.bundle("com.todesktop.other").vendor.map(Client.watchedVendors.contains) == false)
        #expect(Client.bundle("com.google.Chrome").vendor.map(Client.watchedVendors.contains) == false)
        #expect(Client.bundle("com.tencent.xin").vendor.map(Client.watchedVendors.contains) == false)
        // Single apps are their own vendor, so quitting one doesn't revoke the rest.
        #expect(Client.bundle("com.microsoft.VSCode").vendor != Client.bundle("com.microsoft.Word").vendor)
        #expect(Client.bundle("com.google.antigravity").vendor != Client.bundle("com.google.antigravity-ide").vendor)
        #expect(Client.bundle("dev.zed.Zed").vendor != Client.bundle("dev.zed.Zed-Preview").vendor)
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

    @Test func rowAllAccessSwitchReflectsRevocableAccessOnly() {
        let claude = Client.bundle("com.anthropic.claudefordesktop")
        #expect(!Pane.hasRevocableAccess(claude, entries: [:], isBlockedFromLocalNetwork: false, filterIsOn: true))
        #expect(Pane.hasRevocableAccess(
            claude, entries: [.fullDiskAccess: Entry(access: .allowed)],
            isBlockedFromLocalNetwork: false, filterIsOn: false))
        #expect(Pane.hasRevocableAccess(
            claude, entries: [.localNetwork: Entry(access: .allowed)],
            isBlockedFromLocalNetwork: false, filterIsOn: true))
        #expect(!Pane.hasRevocableAccess(
            claude, entries: [.localNetwork: Entry(access: .allowed)],
            isBlockedFromLocalNetwork: false, filterIsOn: false))
        #expect(!Pane.hasRevocableAccess(
            claude, entries: [.localNetwork: Entry(access: .allowed)],
            isBlockedFromLocalNetwork: true, filterIsOn: true))
        #expect(!Pane.hasRevocableAccess(
            .path("/usr/local/bin/tool"), entries: [.fullDiskAccess: Entry(access: .allowed)],
            isBlockedFromLocalNetwork: false, filterIsOn: true))
    }
}
