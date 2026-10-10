# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Each release's notes on GitHub come
from its section below.

## [1.3.0] - 2026-10-09

### Added

- A **Running** column. Switching it off stops the app, its helpers, and everything they
  started, as Stop App does; switching it on opens the app. It replaces the dot under
  running apps' icons.
- **Input Monitoring** and **Full Disk Access** columns, revoked with `tccutil` like
  Device Control.
- An **Other** column: a menu that resets access macOS 27 doesn't let Revoke see, listing
  what each app can ask for. That's Automation (controlling other apps with Apple
  events, as AppleScript does: Terminal, Finder, System Events, UTM), the camera, the
  microphone, Files & Folders, App Management, and Contacts, Calendars, Reminders &
  Photos.
- Revoke's network filter now also stops devices on your network connecting to an app
  whose Local Network is switched off.
- A "What macOS doesn't let Revoke do" section in Settings.

### Changed

- Revoke All Watched and the automatic options cover the new columns, and reset
  everything under Other. They leave apps running; Stop All Apps stops them.
- The menu bar lock, and the list of other apps with access, count Input Monitoring as
  well as Device Control and Screen Recording.

### Fixed

- After you turn down a link from a command, the panel says "Kept a command (curl) in
  Terminal from opening Claude", not "Kept A command".

## [1.2.0] - 2026-10-09

### Added

- A **Links** column. Web pages, emails, documents and other apps can open an agent
  with a link (`claude://`, `codex://`, `claude-cli://`) or a file (`.skill`, `.mcpb`,
  `.dxt`), carrying instructions for it, even while it's quit. Switched off, macOS
  opens Revoke in the app's place, which shows the whole link and what's opening it,
  and opens the app only if you say so. It needs no admin, keeps working while Revoke
  isn't running, and takes links back within two seconds when an app registers them
  again. macOS asks you to confirm each file type. Revoke All Watched and the automatic
  revokes switch it off too (link schemes only, for the automatic ones).
- **Give All Links Back** in Settings, and `Revoke --restore-links`, for before you
  remove Revoke.
- **Stop App** when you right-click an app in the panel: it stops the app, its
  helpers, and everything they started, such as an agent's shells and tools.
- **Stop All Apps**, beside Revoke All Watched and in a new menu you get by
  right-clicking the menu bar icon: it stops every watched app that way, and leaves
  the switches as they are.
- Right-click an app under Other apps with access to watch it or hide it from that
  list; hidden apps are listed in Settings, where you can show them again. Right-click
  a watched app to stop watching it.
- A line under Codex Computer Use ("ChatGPT's computer use agent").

## [1.1.5] - 2026-10-09

### Added

- A line under Claude Code ("Runs Claude's Code tab") and ChatGPT ("Includes
  Codex") in the panel and Settings, saying what each app is.

## [1.1.4] - 2026-10-09

### Fixed

- Tooltips in the panel no longer change how its glass background looks. They
  sit just below what they describe, so they don't cover it.

## [1.1.3] - 2026-10-09

### Fixed

- Tooltips no longer blur the panel's switches around them.
- The status counts helpers as the app they belong to, so it says "Claude is
  running" rather than "Claude and Claude Helper are running".

## [1.1.2] - 2026-10-09

### Added

- Tooltips on everything in the panel and Settings, saying what each permission
  lets an app do, what each button and option does, and why the lock is open or
  closed.

### Fixed

- The running dots and the menu bar lock follow apps as they launch and quit,
  even while the panel is open.
- Clicking outside the panel closes it.

## [1.1.1] - 2026-10-09

### Fixed

- Revoke no longer crashes when the network filter can't be reached, for example
  while the filter restarts after an update.

## [1.1.0] - 2026-10-09

### Changed

- The menu bar lock now opens while any watched app is running, not only while
  one has access, and closes when none is. The status text says which are running.
- The panel shows a dot under the icon of each app that is running.

## [1.0.0] - 2026-10-04

### Added

- A menu bar panel with a switch per app for Device Control and Data Access,
  Screen & System Audio Recording, and Local Network. The menu bar lock opens
  while a watched app has Device Control or Screen Recording.
- Switching Device Control or Screen & Audio off revokes it with Apple's
  `tccutil`, and the app asks again the next time it needs access. Switching it
  on opens the right pane of System Settings, because only you can grant access.
- A network filter, installed from Settings, that keeps an app off your local
  network while you have its Local Network switched off. Commands the app starts
  are blocked too, and the internet stays reachable.
- Revoke All Watched, and automatic revoking when a watched app quits, after a
  time limit, or when the Mac sleeps or the screen locks.
- A Deleted apps section that clears the permissions macOS keeps after an app is
  deleted or replaced.
- Apps from Anthropic and OpenAI are watched by default.

[1.3.0]: https://github.com/benjweaver/revoke/releases/tag/v1.3.0
[1.2.0]: https://github.com/benjweaver/revoke/releases/tag/v1.2.0
[1.1.5]: https://github.com/benjweaver/revoke/releases/tag/v1.1.5
[1.1.4]: https://github.com/benjweaver/revoke/releases/tag/v1.1.4
[1.1.3]: https://github.com/benjweaver/revoke/releases/tag/v1.1.3
[1.1.2]: https://github.com/benjweaver/revoke/releases/tag/v1.1.2
[1.1.1]: https://github.com/benjweaver/revoke/releases/tag/v1.1.1
[1.1.0]: https://github.com/benjweaver/revoke/releases/tag/v1.1.0
[1.0.0]: https://github.com/benjweaver/revoke/releases/tag/v1.0.0
