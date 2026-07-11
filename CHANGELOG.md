# Changelog

## v0.2.3

- Fixed the missing menu entry by adding `sorting_hint = "tools"`.
- KOReader Remote now appears directly under **Tools**.
- No HTTP API or web-interface changes.

## v0.2.2

- Fixed plugin initialization by loading settings inside `init()`.
- Changed settings storage to separate KOReader-native keys.
- Added migration support for the previous v0.2.x settings table.
- Fixed the port dialog input getter.
- Restored the **KOReader Remote** entry in the **Tools** menu.

## v0.2.1

- Fixed plugin loading on fresh installations.
- Safely handles missing or invalid saved settings.
- Restores the **KOReader Remote** entry in the **Tools** menu.
- No changes to the HTTP API or web interface.

## v0.2.0

- Added a persistent autostart option.
- Added automatic restart after standby and resume when autostart is enabled.
- Added a configurable server port.
- Improved firewall cleanup when the port changes.
- Added version and server settings to `/api/ping`.
- Kept KOReader Remote directly in the **Tools** menu.

## v0.1.1

- Moved **KOReader Remote** directly into the **Tools** menu.
- No functional changes to the HTTP server or remote-control interface.

## v0.1.0

- Initial working release.
- Local HTTP server on port 8081.
- Previous and next page controls.
- Minimal phone web interface.
