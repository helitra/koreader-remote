# Changelog

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
- Replaced the previous multi-job release workflow with one small validation-and-release job.
- Git tags now validate the version, build the plugin-only ZIP, generate its SHA-256 checksum, and create or update the GitHub release automatically.

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
