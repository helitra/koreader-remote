# Changelog

## v0.4.0

### Added

- A single `VERSION` file for release versioning.
- Local validation through `scripts/check.sh`.
- Reproducible release archives through `scripts/build-release.sh`.
- Automatic SHA-256 checksums for release archives.
- GitHub Actions checks on pushes and pull requests.
- Automatic GitHub Releases when a matching `v*` tag is pushed.
- Automatic pre-release marking for tags such as `v0.5.0-beta.1`.
- Compatibility documentation and a manual test checklist.
- GitHub issue templates for bug reports and compatibility tests.
- Contributor documentation.

### Changed

- The plugin version is now `0.4.0`.
- The install ZIP now has one clear top-level folder:
  `koreaderremote.koplugin`.

### Reader-facing behavior

The remote-control features are unchanged from v0.3.0:

- Automatic IP detection
- Pairing link
- QR code
- Autostart
- Configurable port
- Previous and next page controls

## v0.3.0

- Added automatic local IPv4 address detection.
- Added display of the actual reader IP address.
- Added a complete pairing link.
- Added QR-code pairing.
- Added a pairing menu action.
- Added `ip` and `url` fields to `/api/ping`.

## v0.2.3

- Placed KOReader Remote directly under **Tools**.
- Added autostart, resume handling and a configurable port.

## v0.1.0

- Initial working release.
