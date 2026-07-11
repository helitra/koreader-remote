# KOReader Remote v0.3.0

A local-network remote control plugin for KOReader.

## Features

- Previous and next page controls from a phone browser
- Automatic local IPv4 address detection
- Displays the real Kindle IP address and complete remote URL
- QR-code pairing that opens the remote website directly
- Pairing dialog shown after manually starting the server
- Persistent autostart option
- Automatic restart after standby/resume when autostart is enabled
- Configurable TCP port
- Default port: 8081
- Kindle firewall handling
- Extended `/api/ping` information

## Installation

1. Stop the existing KOReader Remote server.
2. Copy the complete folder `koreaderremote.koplugin` into:
   `koreader/plugins/`
3. Replace the previous plugin folder when upgrading.
4. Restart KOReader completely.
5. Open a book.
6. Go to:
   `Tools -> KOReader Remote -> Start remote server`
7. KOReader displays the detected IP address and pairing link.
8. Select **Show QR code** and scan it with the phone camera.

## Pairing

The QR code contains the complete local URL, for example:

`http://192.168.1.42:8081/`

Scanning it opens the KOReader Remote website directly. No app is required.

This is convenience pairing only. Version 0.3.0 does not use an access token
or authentication.

## Autostart

Enable:

`Tools -> KOReader Remote -> Auto start remote server`

When enabled, the server starts with KOReader and starts again after
standby/resume. Open **Pair phone / show QR code** to display the current
network address.

## Custom port

Open:

`Tools -> KOReader Remote -> Port`

Choose a port between 1 and 65535.

## API

- `GET /api/ping`
- `GET /api/next`
- `GET /api/previous`

Example `/api/ping` response:

```json
{
  "ok": true,
  "version": "0.3.0",
  "port": 8081,
  "autostart": false,
  "ip": "192.168.1.42",
  "url": "http://192.168.1.42:8081/"
}
```

## Notes

- Use the plugin only on a trusted local network.
- The phone and Kindle must be able to communicate with each other.
- Guest Wi-Fi networks may block device-to-device communication.
- A fully sleeping Kindle cannot be awakened through the remote server.
