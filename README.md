# Revoke

A menu bar app that shows what AI agents such as Claude, ChatGPT/Codex, and Codex
Computer Use can do on your Mac, and takes it away: Device Control, Screen & System
Audio Recording, Input Monitoring, Full Disk Access, Automation, the camera and
microphone, files and folders, and the local network. It also stops web pages, emails, and documents
from opening an agent with a link that carries a prompt, and stops the agents
themselves, along with everything they started. Agents need some of this while they
work, and shouldn't keep it afterwards.

## What it does

One row per watched app and one switch per column. A switch is orange while the app
can do that. The menu bar lock is open while any watched app is running or can control
the Mac or see what's on it (Device Control, Screen Recording, or Input Monitoring).

| Column | Orange means | Switching it off |
|---|---|---|
| Running | The app, its helpers, or something they started, such as an agent's shells and tools, is running | Stops all of it (**Stop App**) |
| Device Control | The app can click, type, and read what's on screen in other apps | Removes it from the list with `tccutil`; it asks again next time |
| Screen & Audio | The app can record the screen and what the Mac plays | The same |
| Input | Input Monitoring: the app can see every key you press and every click | The same |
| Full Disk | Full Disk Access: the app can read and change all your files, other apps' data included | The same |
| Local Network | The app can reach devices on your network, or they can connect to it | Blocks both with Revoke's network filter (below) |
| Links | Web pages, emails, documents, and other apps can open it with a link (`claude://`, `codex://`, `claude-cli://`) or a file (`.skill`, `.mcpb`) | Revoke opens instead, shows you the whole link and who sent it, and opens the app only if you say so (below) |
| Other | A menu rather than a switch: what the app can ask for that macOS doesn't let Revoke see (below) | Choose one to reset it with `tccutil`, or all of them |

**Other** covers Automation (controlling other apps with Apple events, as AppleScript
does: Terminal, Finder, Mail, System Events, UTM), the camera, the microphone, Files &
Folders (Desktop, Documents, Downloads, and network and removable volumes), App
Management (changing or deleting other apps), and Contacts, Calendars, Reminders &
Photos. macOS 27 keeps these in each user's privacy database, which only Apple's own
software can read, so Revoke can't show who has them. It can reset them: the app asks
again the next time it needs one. The menu lists what each app can ask for, from its
`Info.plist` and entitlements. Any app can ask for Files & Folders and App Management;
on this Mac, Claude and ChatGPT can ask for all of these (ChatGPT's personal data is
Calendars and Reminders, Claude's is Photos), and Claude Code for Automation and the
microphone.

Switching Running on opens the app. Switching anything else on opens the right pane of
System Settings, because only you can grant access. Switching Local Network back on
lifts Revoke's block.

**Revoke All Watched** switches off every column but Running for every watched app, and
resets everything under Other.
Apps keep running, but have to ask again for what they need. **Stop All Apps**, beside
it and in the menu you get by right-clicking the menu bar icon, stops every watched
app, and leaves the other switches as they are. To stop one app, switch its Running off,
or right-click it and choose **Stop App**: handy for an app, or a helper it left
behind, running with no window to close.

Below the watched apps, the panel lists apps you don't watch that have Device Control,
Screen Recording, or Input Monitoring. Right-click one to watch it, or to
hide it from that list; hidden apps are listed in Settings, where you can show them
again. Hiding an app doesn't change its access. Right-click a watched app to stop
watching it. A Deleted apps section clears the permissions macOS keeps after an app is
deleted or replaced.

It can also revoke automatically, if you turn these on in Settings:

- **when a watched app quits.** Every watched app from the same developer is revoked
  once none of them are open, so quitting ChatGPT also covers Codex Computer Use.
- **after a time limit**, from 15 minutes to 4 hours after access was switched on.
- **when the Mac sleeps or the screen locks.**

These switch Links off too, for link schemes. File types are left as they are, because
macOS asks you to confirm each one and nobody may be there to answer. Apps keep running.

Apps from Anthropic and OpenAI are watched by default. Any other app can be added in
Settings. On macOS, OpenAI's are ChatGPT, which is the Codex app renamed (it keeps
Codex's bundle ID and `codex://` links, and bundles the Codex CLI), and Codex Computer
Use, a background app of its own that macOS also calls ChatGPT Computer Use.

## Install

On macOS:

```sh
brew install --cask benjweaver/revoke/revoke
```

Or download `Revoke-<version>.zip` from Releases and move Revoke to Applications,
the only place macOS runs its network filter from. Releases are signed with a
Developer ID and notarized by Apple, so macOS opens them without a warning. Open
Revoke, give it Full Disk Access, and install the network filter from its settings.

To uninstall, first choose **Give All Links Back** and **Remove Network Filter** in
Revoke's settings, so every app opens its own links again and the filter goes too,
then delete Revoke (`brew uninstall --cask revoke`). From a script,
`/Applications/Revoke.app/Contents/MacOS/Revoke --restore-links` gives the links back
(it quits a running Revoke first). If Revoke is deleted without that, macOS hands each
link to an app that registers it, which isn't always the one that had it.

On Windows, [Revoke for Windows](https://github.com/benjweaver/revoke-windows) does the
same job from the notification area. In PowerShell, with no admin rights:

```powershell
irm https://raw.githubusercontent.com/benjweaver/revoke-windows/main/packaging/windows/install.ps1 | iex
```

Its README covers updating and removing it, and what Windows lets it do.

## What it can't do, and why

macOS keeps these permissions in a database that System Integrity Protection guards.
No app outside Apple can write to it, not even as root. That's deliberate: otherwise
malware could give itself screen recording. So:

- **Turning access on** opens the right pane of System Settings. Only you can grant
  access, with your password or Touch ID.
- **Turning access off** uses `tccutil reset`, the command-line tool Apple ships for
  exactly this. It needs no admin rights.
- **Local Network** can't be changed by any app other than System Settings (it's
  stored by NetworkExtension, root-only, in a private format), so Revoke blocks the
  traffic itself instead. See below.
- **System Audio Recording Only** is stored in a per-user database that macOS 27 keeps
  in a protected container no app can read. Revoke can't show it, but revoking Screen &
  Audio clears it too.
- **Command-line tools** without a bundle ID (listed by path) can only be changed in
  System Settings.
- **Location Services** keeps its list in a file only macOS's location daemon can read,
  and `tccutil` can't reset it, so Revoke doesn't show it or change it.
- **Open at Login and Allow in the Background** are kept in a list only macOS can
  change, and apps like Claude and ChatGPT add themselves through an API that only the
  app itself can undo. Remove one in System Settings › General › Login Items &
  Extensions.
- **Automation, the camera and microphone, and the rest under Other** are kept in each
  user's privacy database, which macOS 27 lets only Apple's own software read: tccd
  answers other apps only with a private Apple entitlement. Revoke resets them with
  `tccutil`, but can't show who has them.
- **Stopping an app when its last window closes**, as Revoke for Windows can, isn't
  possible here. macOS doesn't tell other apps whether a window was closed, minimized,
  or moved to another Space, so Revoke acts when the app quits instead.
- **Stopping an app reaches what it started, while they're still its children.** A
  process an app started and then left behind, which macOS hands to `launchd`, can't
  be traced back to the app, by Revoke or anyone else.
- **Links only cover what goes through macOS's link and file handling.** A process
  already running as you can start an app directly, with `open -a Claude` or by
  running its binary, and pass it whatever it likes. Revoke is about what reaches the
  app from outside: web pages, emails, documents, and chat messages.
- **File types need your say-so.** macOS asks you to confirm every change to which app
  opens a file type, so switching Links off for an app that opens `.skill` files shows
  a macOS dialog for each type, and so does switching it back on.
- **An app can take its links back.** Revoke notices within two seconds while it's
  running and takes link schemes back, but a link opened in that moment, or while
  Revoke isn't running after the app re-registered, goes straight to the app. A file
  type an app takes back stays with it until you switch Links off again, since taking
  it means a macOS dialog; the switch turns orange to show it.

## Blocking Local Network

Revoke carries a network content filter, a system extension like the one LuLu and
Little Snitch use, which you install from Revoke's settings. macOS asks you to allow it
twice: once in System Settings > General > Login Items & Extensions, and once to let it
filter network content.

While an app's Local Network is switched off in Revoke, the filter drops its
connections to local-network addresses (private and link-local ranges, multicast, and
broadcast), and connections from devices at those addresses to servers the app runs. Commands the app starts count as the app, so an agent can't reach your
router by running `curl` or `ssh` either; the filter checks the process macOS holds
responsible as well as its parents. The internet and servers on this Mac (loopback)
stay reachable, matching macOS's own Local Network rule.

The filter only sees connections to and from local-network addresses, and if it stops
or crashes macOS lets traffic through rather than cutting the Mac off. It can't block
Bonjour discovery, which macOS's own mDNSResponder does on an app's behalf. Only Revoke,
signed with the same Developer ID, can change what it blocks.

## Links

A quit agent isn't out of reach. Any web page can ask the browser to open a
`claude://` or `codex://` link, an email or a chat message can carry one, and macOS
starts the app with whatever the link holds; a downloaded `.skill` or `.mcpb` file
opens in Claude or Codex the same way. That can hand an agent instructions while you're
away, or dressed up as something else: prompt injection that doesn't wait for the app
to be open.

Revoke reads each watched app's `Info.plist` for the link schemes and file types it
registers, and the Links switch covers the ones macOS opens with that app now. On this
Mac that's `claude://` for Claude, `codex://` for ChatGPT (which also lists `http` and
`https`, but those belong to your browser and Revoke never touches them), `.skill`,
`.dxt`, and `.mcpb` files, and Claude's sign-in scheme. Claude Code registers
`claude-cli://` by writing itself a small URL Handler app in `~/Applications`, which
Revoke shows under Claude Code.

Switching **Links** off makes Revoke the app macOS opens those with, through
LaunchServices' own per-user setting, so it needs no admin rights and keeps working
while Revoke isn't running: macOS starts Revoke for the link. Revoke then asks:

> Safari wants to open Claude with this link:
>
> `claude://claude.ai/new?q=Ignore your instructions and…`
>
> Open it only if you just clicked it yourself. A link can carry instructions for
> Claude, like a prompt for it to run. Open Claude?

It names the app that asked macOS to open the link, decodes the link's `%`-escapes so
a prompt in it reads as text, shows anything that can hide or reorder text (right-to-left
overrides, zero-width characters, controls) as a `\uXXXX` code, and cuts very long links
short. **No** is the default answer. Say **Yes** and Revoke opens the app with the link,
straight to the app as macOS would have. It asks every time, whether or not the app is
running.

Revoke saves which app had each link, so switching Links back on gives it back to that
app. Apps can make themselves their links' handler again: ChatGPT does it each time it
starts, Claude's code can do the same (both use Electron's `setAsDefaultProtocolClient`),
and Claude Code re-registers `claude-cli://` daily. While Revoke runs, it notices within
two seconds, takes the link back, and says so ("ChatGPT registered its links again, so
Revoke took them back").

Link schemes change hands silently. File types don't: macOS shows its own dialog
asking you to confirm, each time any app becomes the one that opens a type, so expect
one per type when you switch Links off or on.

## Full Disk Access

Revoke needs Full Disk Access to *read* the permissions database
(`/Library/Application Support/com.apple.TCC/TCC.db`) and show who has Device Control,
Screen Recording, Input Monitoring, and Full Disk Access. It opens the file read-only,
and System Integrity Protection would stop it from writing anyway. Without Full Disk
Access, revoking still works, but those columns show question marks.

macOS applies Full Disk Access when an app restarts, so choose **Quit & Reopen** after
switching it on.

## Build

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen). macOS 15 or later;
built and tested on macOS 27.

```sh
Scripts/install.sh
```

This archives Revoke, exports it signed with the team's Developer ID, notarizes it,
and installs it in `/Applications`. The filter's entitlements come with provisioning
profiles, so Xcode has to be signed in to the team (`DEVELOPMENT_TEAM` in
`project.yml`); the build lets it create them. Full Disk Access belongs to the
signature, which stays the same across builds.

To build your own copy, put your team ID in place of `AR25V66TVY` in `project.yml`,
`Shared/FilterControl.swift`, and `Scripts/release.sh`: the filter's XPC service, its
app group, and the signature it accepts changes from all carry it.

The tests take a made-up link scheme for the Revoke they build, check Revoke is its
handler, give it back, and check LaunchServices' record of the choice is as it was.
They register made-up apps of their own and remove them afterwards; LaunchServices
keeps its record of the made-up scheme, which macOS has no way to delete. They don't
need signing:

```sh
xcodegen generate
xcodebuild test -project Revoke.xcodeproj -scheme Revoke CODE_SIGNING_ALLOWED=NO
```

Every revocation, every connection the filter drops, and every link Revoke stands in
for is logged:

```sh
log show --last 1d --predicate 'subsystem BEGINSWITH "dev.benjweaver.Revoke"'
```

## Support

Revoke is free. If it's useful, you can [support its development](https://benjweaver.dev/support/revoke).

## Release

Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` (macOS only
replaces the network filter when its build number changes), add the version's section
to `CHANGELOG.md`, then commit and push. `Scripts/release.sh` does the rest: it builds
a universal app, signs it with the Developer ID, has Apple notarize it, publishes the
zip as a GitHub release with that changelog section as the notes, and points the
[Homebrew tap](https://github.com/benjweaver/homebrew-revoke) at it.

Notarizing needs an App Store Connect API key, saved once in the keychain as the
notarytool profile `notary`:

```sh
xcrun notarytool store-credentials notary --key AuthKey_<key id>.p8 --key-id <key id> --issuer <issuer id>
```

## License

GPL-3.0-or-later.
