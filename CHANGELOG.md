# Changelog

## v0.8.4

### Added

- Added a dedicated `🔖` phone tab for annotations from the currently open book.
- Added a combined list of page bookmarks, highlights, and notes.
- Added **All**, **Bookmarks**, **Highlights**, and **Notes** filters.
- Added chapter, page or position, selected-text excerpt, and attached-note display.
- Added tap-to-open navigation from the phone to the selected Kindle annotation.
- Added `GET /api/v1/bookmarks`.
- Added `POST /api/v1/bookmarks/open?id=...`.
- Added stale-list detection so a changed annotation list is refreshed instead of opening the wrong entry.
- Added a 300-item response limit and bounded text fields for predictable local-network payloads.

### Changed

- Opening an annotation from the phone adds the current Kindle location to KOReader's navigation history before jumping.
- OLED inactivity dimming now remains disabled while either the note editor or bookmarks tab is open.

### Compatibility

- Annotation editing and deletion are intentionally not part of this release.
- Remote notes, footnote automation, OLED mode, page controls, device controls, updater behavior, pairing, sleep recovery, and autostart remain unchanged.

## v0.8.3

### Added

- Added a native Kindle note dialog for **Write note on phone** and **Edit note on phone** sessions.
- Added live access to the current unsaved Kindle note draft through **Pull from Kindle**.
- Added draft-only **Push to Kindle** behavior: phone text now fills the open Kindle note field without saving the annotation.
- Added a separate **Save note** button on the phone.
- Added `/api/v1/note-session/save` for explicitly committing the shared draft.
- Added feedback when a note is saved or cancelled on either device.

### Changed

- A remote-note session can now be edited on Kindle and phone interchangeably before it is saved.
- The Kindle **Save** button and the phone **Save note** button commit the same shared draft.
- Cancelling a new remote note discards its temporary highlight, matching KOReader's native new-note workflow.
- Draft revisions now change when the open Kindle text field changes, preventing silent cross-device overwrites.

### Compatibility

- Base64 transport, OLED mode, footnote automation, page controls, device controls, updater behavior, pairing, sleep recovery, and autostart remain unchanged.

## v0.8.2

### Fixed

- Fixed phone-to-KOReader note pushes being rejected with **“The encoded note contains invalid characters.”**
- Replaced an unsupported regular-expression quantifier with explicit Lua-compatible Base64 padding validation.
- Added decoded-length validation after Base64 decoding.
- Added support for pushing an empty note, allowing an existing note to be cleared from the phone.

### Compatibility

- Remote-note selection, OLED mode, footnote automation, Pull/Push routes, page controls, device controls, updater behavior, pairing, sleep recovery, and autostart are otherwise unchanged.

## v0.8.1

### Fixed

- Fixed a reproducible KOReader crash after selecting **Write note on phone** on KOReader 2026.03.
- Added compatibility with both KOReader highlight APIs: the direct `saveHighlight()` path used by KOReader 2026.03 and the optional `showHighlightPrompt()` callback used by other builds.
- Added a protected execution boundary around remote-note highlight actions so an unexpected integration error shows a message instead of terminating KOReader.
- Changed the selection-availability check to return a strict boolean.

### Compatibility

- OLED mode, footnote automation, the phone note editor, Pull/Push routes, page controls, device controls, updater behavior, pairing, sleep recovery, and autostart are otherwise unchanged.

## v0.8.0

### Added

- Added a pencil icon that opens a dedicated phone note editor without changing the main page-turn layout.
- Added **Write note on phone** to KOReader's selected-text highlight actions.
- Added **Edit note on phone** for existing highlights and notes through the highlight action menu.
- Added explicit **Pull from Kindle** and **Push to Kindle** note actions.
- Added note-session revision checks to prevent silent overwrites after a note changes on the reader.
- Added one active, document-bound note session with a 30-minute expiry and a 12 KiB note limit.
- Added automatic note-session cancellation when the document closes or changes.
- Added a `¹` toolbar action that opens the next current-page link accepted by KOReader's footnote-popup detection.
- Added an optional OLED mode with true-black backgrounds, darker static elements, browser-local persistence, and inactivity dimming.
- Added Home Screen status-bar metadata for a darker Safari standalone experience.
- Added `GET /api/v1/note-session`, `POST /api/v1/note-session/push`, `POST /api/v1/note-session/cancel`, and `POST /api/v1/footnote/open`.
- Added `interaction.lua` to isolate note and footnote integration from the HTTP server lifecycle.

### Changed

- The capabilities response now reports `remote_notes` and `footnotes` support for the current KOReader view.
- The updater now requires `interaction.lua` in future installed releases.
- The top status area now contains compact footnote, note, and OLED controls while the large lower page-turn zones remain unchanged.

### Security and limits

- Remote-note text is Base64-encoded UTF-8 in a bounded request header because KOReader's simple TCP HTTP server does not consume request bodies.
- A remote note can be pushed only while a user-created note session is active on the reader.
- The existing trusted-local-network warning still applies; there is no authentication token.
- Footnote automation is experimental and limited to reflowable documents supported by KOReader's current footnote-popup detection.

## v0.7.1

### Changed

- Added the stable update channel to update-check results.
- Added the plugin ZIP download size to the update confirmation.
- Clarified that the currently installed plugin is backed up before installation.
- Kept this release intentionally small so the complete v0.7.0 → v0.7.1 self-update path can be tested in isolation.

### Compatibility

- No server, web interface, device-control, pairing, autostart, sleep, QR-code, archive-validation, backup, rollback, or restart behavior changed.

## v0.7.0

### Added

- Added **Check for updates** to `Tools → KOReader Remote`.
- Added a non-interactive menu row showing the currently running plugin version.
- Added a manual, stable-release update check using the public GitHub Releases API.
- Added confirmation before downloading and installing an available update.
- Added automatic download of the exact plugin ZIP and its SHA-256 checksum.
- Added redirect handling for GitHub release asset downloads.
- Added SHA-256 verification with KOReader's bundled hashing implementation.
- Added safe archive inspection and extraction through KOReader's bundled libarchive wrapper.
- Added path-traversal, symlink, duplicate-path, file-count, and size checks.
- Added Lua syntax validation before changing the installed plugin.
- Added staged installation, a sibling backup directory, and immediate rollback when installation fails.
- Added a KOReader restart prompt after a successful installation.
- Added automatic cleanup of the previous-version backup after the updated plugin starts successfully.

### Changed

- Update checks happen only after an explicit user action. There is no background polling.
- Stable GitHub releases are offered; drafts and pre-releases are not installed by this updater.
- The remote server is stopped only after a downloaded update has passed all checks.
- Choosing to restart later leaves the running old plugin session stopped until KOReader restarts.

### Security

- The updater accepts only release assets named `koreaderremote-vX.Y.Z.zip` and `koreaderremote-vX.Y.Z.zip.sha256`.
- Every archive entry must stay inside `koreaderremote.koplugin/`.
- Only regular files and directories are accepted.
- The existing plugin is retained as `koreaderremote.koplugin.previous` until the new version starts successfully.

## v0.6.3

### Fixed

- Fixed brightness fine adjustment briefly changing and then snapping back to the previous percentage.
- Fixed hold-to-repeat values being overwritten by device-state responses while an adjustment was still in progress.
- Preserved the normalized percentage selected by the user when several percentages map to the same native front-light level.
- Added a short synchronization grace period for readers whose light-state getter updates asynchronously.
- Applied the same request synchronization protection to warmth adjustment.

### Changed

- Device settings now start collapsed whenever the remote website is opened.
- Removed the saved expanded or collapsed panel preference.
- The API now also reports effective hardware brightness and warmth values alongside the normalized displayed values.

### Compatibility

- Presets, fine-adjustment timing, page controls, API routes, pairing, autostart, sleep behavior, and QR-code behavior remain unchanged.

## v0.6.2

### Changed

- Replaced the brightness and warmth sliders with large preset buttons and fine-adjustment controls.
- Added brightness presets for 1%, 10%, 25%, 50%, 75%, and 100%.
- Added warmth presets for 0%, 25%, 50%, 75%, and 100%.
- A normal minus or plus tap changes the value by exactly one percentage point.
- Holding minus or plus starts repeating after 500 milliseconds.
- Hold acceleration changes only the repeat timing; every individual step remains exactly one percentage point.
- Limited the fastest hold rate to approximately 4.3 steps per second.
- Guaranteed a final device update when the user releases or leaves a fine-adjustment button.
- Made Device settings open on a first visit while retaining the user's later collapsed or expanded preference.
- Matched the approved dark Safari-oriented layout with status, device controls, and large lower page-turn zones.

### Compatibility

- No server, API, pairing, lifecycle, autostart, sleep, or QR-code behavior changed.
- Existing device-control endpoints remain unchanged.
- All v0.6.1 English-language and thumb-friendly page-turn behavior remains available.

## v0.6.1

### Changed

- Changed the complete phone website to English.
- Moved the compact, collapsible device-settings panel to the top of the screen.
- Made the previous-page and next-page controls fill all remaining screen space down to the phone's safe-area edge.
- Kept the next-page control on the lower-right side for easier thumb access.
- Increased the page-turn arrow size and improved touch, focus, and small-screen behavior.
- Updated the README and automated validation for the new layout and language.

### Compatibility

- No API, server-lifecycle, pairing, device-control, or KOReader menu behavior changed.
- All v0.6.0 device controls and all v0.5.0 reliability behavior remain available.

## v0.6.0

### Added

- Added capability-aware device controls to the phone website.
- Added frontlight on/off control on supported devices.
- Added brightness control with device-specific value conversion.
- Added warm-light control on devices that report natural-light support.
- Added KOReader night-mode control.
- Added a manual full-screen refresh action on supported E-Ink devices.
- Added `GET /api/v1/capabilities` and `GET /api/v1/device-state`.
- Added restricted `POST /api/v1/*` endpoints for supported device actions.
- Added `devicecontrols.lua` to keep hardware control logic separate from the server lifecycle.

### Changed

- Device controls are hidden automatically when the reader does not support them.
- Brightness and warmth slider requests are debounced to avoid flooding the reader.
- Device state is synchronized again after reconnecting to the reader.
- The release workflow now creates the version tag automatically when manually started from `main`.
- GitHub release descriptions are now taken directly from the matching `CHANGELOG.md` section.
- Release ZIP and SHA-256 files are still built automatically and contain only the plugin folder.

### Compatibility

- Legacy page-turn endpoints remain available unchanged.
- The existing v0.5.0 manual-session, sleep, reconnect, URL, and QR-code behavior remains unchanged.

## v0.5.0

- Added reliable Wi-Fi recovery after standby and resume.
- Added retry delays of 2, 5, 10, 20, and 30 seconds while waiting for Wi-Fi.
- Added clear server states: stopped, waiting, starting, running, retrying, and error.
- Added a **Test connection** menu action with compact diagnostics.
- Added automatic reconnect checks to the phone website without resetting KOReader's sleep timer.
- Pairing URL and QR payload now change only when the IP address or port really changes.
- A manually started server now stays active when closing a book, opening the file manager, or opening another book.
- Manual sessions return after a sleep of up to five minutes and remain stopped after a longer sleep.
- Autostart sessions continue to return after any sleep duration.
- An explicit manual stop now suppresses autostart until KOReader is restarted or the server is started again.
- Closing KOReader or disabling the plugin cleans up the server and Kindle firewall rule.
- Page-turn requests now return `409 Conflict` when no document is open.
- Added `state`, `manual_session`, `document_open`, `url_revision`, and `manual_sleep_grace_seconds` to `/api/ping`.

## v0.4.0

- Added release validation and packaging infrastructure.
- Added a `VERSION` file and version checks.
- Added automatic ZIP and SHA-256 generation.
- No remote-control behavior changes.

## v0.3.0

- Added automatic local IPv4 address detection.
- Added display of the actual reader IP address.
- Added a complete pairing link and QR-code pairing.
- Added `ip` and `url` fields to `/api/ping`.

## v0.2.3

- Fixed the menu entry with `sorting_hint = "tools"`.
- Added autostart, resume handling, and a configurable port.

## v0.1.0

- Initial working release.
- Added a local HTTP server and phone web interface.
- Added previous and next page controls.
