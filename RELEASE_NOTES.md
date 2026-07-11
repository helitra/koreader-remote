## KOReader Remote v0.3.0

### Added

- Automatic detection of the Kindle's local IPv4 address
- Display of the real IP address and complete remote URL
- QR-code pairing that opens the remote website directly
- `Pair phone / show QR code` menu action
- `ip` and `url` fields in `/api/ping`
- Automatic connection-address refresh after Wi-Fi connects

### Pairing

1. Open `Tools → KOReader Remote`.
2. Start the remote server.
3. KOReader displays the detected address.
4. Select `Show QR code`.
5. Scan the QR code with the phone camera.

The QR code contains a URL such as:

`http://192.168.1.42:8081/`

### Upgrade

1. Stop the old remote server.
2. Replace `koreader/plugins/koreaderremote.koplugin`.
3. Restart KOReader completely.

### Security

This release intentionally has no access token or authentication. Use it only
on a trusted local network.
