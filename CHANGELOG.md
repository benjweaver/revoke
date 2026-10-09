# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Each release's notes on GitHub come
from its section below.

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

[1.1.4]: https://github.com/benjweaver/revoke/releases/tag/v1.1.4
[1.1.3]: https://github.com/benjweaver/revoke/releases/tag/v1.1.3
[1.1.2]: https://github.com/benjweaver/revoke/releases/tag/v1.1.2
[1.1.1]: https://github.com/benjweaver/revoke/releases/tag/v1.1.1
[1.1.0]: https://github.com/benjweaver/revoke/releases/tag/v1.1.0
[1.0.0]: https://github.com/benjweaver/revoke/releases/tag/v1.0.0
