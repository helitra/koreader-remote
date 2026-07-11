# KOReader Remote v0.2.3

A minimal KOReader plugin that serves a local phone-friendly remote control.

## Features

- Start/stop directly from KOReader's **Tools** menu
- Persistent autostart option
- Automatically restarts after standby/resume when autostart is enabled
- Configurable TCP port
- Default port: 8081
- Previous page
- Next page
- Local status endpoint
- Opens/removes Kindle firewall rules while running
- Stops cleanly on standby, suspend, KOReader exit, or UI close

## Installation

1. Stop the currently running KOReader Remote server.
2. Copy the complete folder `koreaderremote.koplugin` into:
   `koreader/plugins/`
3. Replace the previous plugin folder when upgrading.
4. Restart KOReader completely.
5. Open a book.
6. Go to:
   `Tools -> KOReader Remote -> Start remote server`
7. On a phone in the same Wi-Fi network, open:
   `http://KINDLE-IP:8081/`

## Autostart

Enable:

`Tools -> KOReader Remote -> Auto start remote server`

When enabled, the server starts with KOReader and starts again after standby/resume.

## Custom port

Open:

`Tools -> KOReader Remote -> Port`

Choose a port between 1 and 65535. If the server is already running, it is restarted on the new port.

## Test endpoints

- `http://KINDLE-IP:PORT/api/ping`
- `http://KINDLE-IP:PORT/api/next`
- `http://KINDLE-IP:PORT/api/previous`

## Notes

- Version 0.2.3 has no authentication.
- Use it only on a trusted local network.
- A fully sleeping Kindle cannot be awakened through this server.

## v0.2.1 hotfix

This release fixes plugin loading on fresh installations where no saved
KOReader Remote settings exist yet.

## v0.2.2 hotfix

- Moves all KOReader settings access into the plugin `init()` lifecycle.
- Uses the same settings pattern as KOReader's built-in plugins.
- Fixes the missing **KOReader Remote** entry in the **Tools** menu.
- Fixes the port dialog to use `getInputText()`.

## v0.2.3 hotfix

- Adds `sorting_hint = "tools"` to the KOReader Remote menu entry.
- Places the plugin directly under **Tools → KOReader Remote**.
- Fixes the missing menu item introduced in v0.1.1.
