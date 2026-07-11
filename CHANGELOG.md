# Changelog

## v0.3.0

- Added automatic local IPv4 address detection.
- Added display of the actual Kindle IP address.
- Added a complete pairing link using the detected IP and configured port.
- Added QR-code pairing using KOReader's built-in QR widget.
- Added a **Pair phone / show QR code** menu action.
- The server-start dialog now shows the real connection details.
- Added `ip` and `url` fields to `/api/ping`.
- Refreshes the connection address after KOReader receives a network-connected event.
- No access token or authentication was added.

## v0.2.3

- Fixed the missing menu entry by adding `sorting_hint = "tools"`.
- KOReader Remote appears directly under **Tools**.
- Added autostart, resume handling and a configurable port.

## v0.1.0

- Initial working release.
- Local HTTP server and phone web interface.
- Previous and next page controls.
