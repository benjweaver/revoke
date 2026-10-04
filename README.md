# Revoke

A menu bar app that shows which apps have Device Control, Screen & System Audio
Recording, and Local Network access, and takes all three away with one click.
It's built for AI agents such as Claude, ChatGPT/Codex, and Codex Computer Use, which
need these permissions while they work and shouldn't keep them afterwards.

## What it does

- **Shows live status.** One row per app and one switch per System Settings list. A
  switch is orange while access is on. The menu bar lock is open while any watched
  app has Device Control or Screen Recording.
- **Revokes.** Switching Device Control or Screen & Audio off removes the app from that
  list, as if it had never asked; the app asks again the next time it needs access.
  Switching Local Network off blocks it with Revoke's network filter (below), and
  switching it back on lifts the block. **Revoke All Watched** does all three for every
  watched app.
- **Revokes automatically**, if you turn these on in Settings:
  - when a watched app quits. Every watched app from the same developer is revoked once
    none of them are open, so quitting ChatGPT also covers Codex Computer Use.
  - after a time limit, from 15 minutes to 4 hours after access was switched on.
  - when the Mac sleeps or the screen locks.

Apps from Anthropic and OpenAI are watched by default. Any other app can be added in
Settings.

## Install

```sh
brew install --cask benjweaver/revoke/revoke
```

Or download `Revoke-<version>.zip` from Releases and move Revoke to Applications,
the only place macOS runs its network filter from. Releases are signed with a
Developer ID and notarized by Apple, so macOS opens them without a warning. Open
Revoke, give it Full Disk Access, and install the network filter from its settings.

To uninstall, choose **Remove Network Filter** in Revoke's settings first, so the
filter goes too, then delete Revoke (`brew uninstall --cask revoke`).

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

## Blocking Local Network

Revoke carries a network content filter, a system extension like the one LuLu and
Little Snitch use, which you install from Revoke's settings. macOS asks you to allow it
twice: once in System Settings > General > Login Items & Extensions, and once to let it
filter network content.

While an app's Local Network is switched off in Revoke, the filter drops its
connections to local-network addresses: private and link-local ranges, multicast, and
broadcast. Commands the app starts count as the app, so an agent can't reach your
router by running `curl` or `ssh` either; the filter checks the process macOS holds
responsible as well as its parents. The internet and servers on this Mac (loopback)
stay reachable, matching macOS's own Local Network rule.

The filter only sees connections bound for local-network addresses, and if it stops
or crashes macOS lets traffic through rather than cutting the Mac off. It can't block
Bonjour discovery, which macOS's own mDNSResponder does on an app's behalf. Only Revoke,
signed with the same Developer ID, can change what it blocks.

## Full Disk Access

Revoke needs Full Disk Access to *read* the permissions database
(`/Library/Application Support/com.apple.TCC/TCC.db`) and show who has access. It
opens the file read-only, and System Integrity Protection would stop it from writing
anyway. Without Full Disk Access, revoking still works, but the Device Control and
Screen columns show question marks.

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

Every revocation, and every connection the filter drops, is logged:

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
