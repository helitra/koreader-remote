# Changelog

## v0.4.0

- Added an automatic GitHub Actions workflow for validation and releases.
- Release tags now build the installable plugin ZIP automatically.
- Release tags also create a SHA-256 checksum automatically.
- Added a `VERSION` file and a check that the tag, file, and Lua version match.
- Added basic Lua syntax and repository structure checks.
- Added a small compatibility section to the README.
- Added the Kobo plugin path to the installation instructions.
- Removed the duplicate `RELEASE_NOTES.md` file from the planned repository structure.
- No changes to the remote-control behavior.

## v0.3.0

- Added automatic local IPv4 address detection.
- Added display of the actual reader IP address.
- Added a complete pairing link using the detected IP and configured port.
- Added QR-code pairing using KOReader's built-in QR widget.
- Added a **Pair phone / show QR code** menu action.
- Added `ip` and `url` fields to `/api/ping`.

## v0.2.3

- Fixed the missing menu entry with `sorting_hint = "tools"`.
- KOReader Remote appears directly under **Tools**.
- Added autostart, resume handling, and a configurable port.

## v0.1.0

- Initial working release.
- Added a local HTTP server and phone web interface.
- Added previous and next page controls.
