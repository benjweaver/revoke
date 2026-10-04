# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Each release's notes on GitHub come
from its section below.

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

[1.0.0]: https://github.com/benjweaver/revoke/releases/tag/v1.0.0
