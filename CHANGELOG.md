# Changelog

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
