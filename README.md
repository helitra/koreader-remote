# KOReader Remote

KOReader Remote is a small plugin that lets you turn pages in KOReader from your phone.

It works over your local Wi-Fi network. You do not need to install an app on your phone. Start the remote server, scan the QR code, and tap left or right to turn the page.

## Why I made this

I made this plugin because I often place my Kindle somewhere on top of my blanket while reading in bed.

Sometimes I lie in bed like a folded protein and do not want to move my hand just to turn the page. I also often have my phone in my hand, or keep it next to my face while getting comfortable.

With KOReader Remote, I can turn pages from my phone without reaching for the Kindle every time.

This project was mostly (okay, basically everything) vibe-coded. It started as a simple idea, then slowly turned into a working KOReader plugin. =)

## Demo

https://github.com/user-attachments/assets/f81e5089-8f5f-4a0a-93cc-433873eff57c

## Features

- Turn one page forward or backward
- Use a simple website in any modern phone browser
- No phone app required
- Automatically detect the reader's local IPv4 address
- Show the full connection link and a QR code
- Keep the same pairing URL and QR payload when IP and port did not change
- Keep a manually started server alive when changing books or opening the file manager
- Restore a manual session after a short sleep of up to five minutes
- Leave a manual session stopped after a longer sleep
- Restore the server after any sleep when autostart is enabled
- Wait for Wi-Fi and retry automatically after standby or resume
- Reconnect the phone website automatically when the reader becomes reachable again
- Show compact server and network diagnostics in KOReader
- Use a configurable server port
- Open and remove the Kindle firewall rule when needed
- Open the plugin directly from `Tools → KOReader Remote`

## Compatibility

- **Kindle:** tested
- **Kobo:** expected to work, but not yet tested on real Kobo hardware
- **Other KOReader devices:** not tested yet

Feedback from other devices is welcome. Please include the exact device model, KOReader version, and plugin version when reporting a result.

## Requirements

- KOReader installed
- A device that allows external KOReader plugins
- Reader and phone connected to the same local network
- A network that allows devices to communicate with each other
- A jailbroken device when required by the platform

Guest Wi-Fi networks may block communication between your phone and reader.

## Installation

1. Download the latest `koreaderremote-v*.zip` file from the Releases page.
2. Extract the ZIP file.
3. Stop KOReader Remote if an older version is running.
4. Copy the folder:

   ```text
   koreaderremote.koplugin
   ```

   into the KOReader plugin directory:

   ```text
   Kindle: koreader/plugins/
   Kobo:   .adds/koreader/plugins/
   ```

5. Replace the old plugin folder when upgrading.
6. Restart KOReader completely.
7. Open a book.
8. Go to:

   ```text
   Tools → KOReader Remote
   ```

9. Select:

   ```text
   Start remote server
   ```

## Pairing

When you start the server, KOReader finds the reader's current local IP address and shows a link such as:

```text
http://192.168.1.42:8081/
```

Select:

```text
Show QR code
```

Scan the QR code with your phone camera. The remote website should open directly in your phone browser.

You can open the pairing screen again from:

```text
Tools → KOReader Remote → Pair phone / show QR code
```

The cached pairing URL and QR payload are replaced only when the detected IP address or configured port actually changes. Waking the reader with the same IP does not create a new URL.

Pairing is only a quick way to open the correct local link. It does not use a password or access token.

## Manual sessions and autostart

`Start remote server` creates a manual session for the current KOReader run.

With autostart disabled:

- closing a book does not stop the server
- opening the file manager does not stop the server
- opening another book reuses the same server and phone page
- a short sleep of up to five minutes restores the session
- a longer sleep leaves the server stopped after wake-up
- closing KOReader stops the server
- pressing **Stop remote server** keeps it stopped for the rest of that KOReader run
- restarting KOReader does not start it again

Enable:

```text
Tools → KOReader Remote → Auto start remote server
```

With autostart enabled:

- the server starts when KOReader starts
- the server returns after short or long sleep
- the plugin waits for Wi-Fi before restarting the server

The server socket and Kindle firewall rule are removed while the reader is sleeping. A sleeping reader cannot be woken through the remote website.

## Reliable reconnect

After wake-up, KOReader Remote:

- waits for a real network connection
- retries after 2, 5, 10, 20, and 30 seconds when Wi-Fi is not ready
- reacts to KOReader's `NetworkConnected` event
- starts the server once a usable local IPv4 address exists
- keeps the old pairing URL when the same IP returns
- updates the URL and QR payload only after a real IP or port change

The phone website checks the connection automatically. Passive status checks do not reset KOReader's sleep timer.

If the reader wakes up with the same IP address, the existing browser page should reconnect without a manual reload. If the IP address changed, scan the current QR code again.

## Using the remote

The remote website has two large buttons:

- Left side: previous page
- Right side: next page

You can also use the left and right arrow keys on a device with a keyboard.

When no book is open, the server remains available but page-turn requests return `409 Conflict`. The phone page then asks you to open a book on the reader.

## Connection status

Open:

```text
Tools → KOReader Remote → Test connection
```

The status window shows:

- plugin version
- server state
- network state
- detected IP address
- configured port
- autostart state
- current session type
- whether a document is open
- current URL
- last server error

## Custom port

The default port is:

```text
8081
```

To change it, open:

```text
Tools → KOReader Remote → Port
```

Enter a port between `1` and `65535`.

If the server is already running, the plugin stops it and starts it again on the new port. Changing the port creates a new pairing URL and QR payload because the address really changed.

## API

KOReader Remote provides a small local HTTP API.

### Status

```http
GET /api/ping
```

Example response:

```json
{
  "ok": true,
  "version": "0.5.0",
  "state": "running",
  "port": 8081,
  "autostart": false,
  "manual_session": true,
  "document_open": true,
  "ip": "192.168.1.42",
  "url": "http://192.168.1.42:8081/",
  "url_revision": 1,
  "manual_sleep_grace_seconds": 300
}
```

`url_revision` increases only when the pairing URL actually changes.

### Next page

```http
GET /api/next
```

### Previous page

```http
GET /api/previous
```

## Notes

- Use KOReader Remote only on a trusted local network.
- This version does not use authentication or an access token.
- Anyone who can reach the reader IP and port may send page-turn commands.
- Reader and phone must be able to communicate directly.
- Guest networks may block local device-to-device traffic.
- A fully sleeping reader cannot be woken through the remote server.
- The reader may receive a different IP address after reconnecting to Wi-Fi.
- Scan the pairing QR code again when the old address no longer works.
- Keeping Wi-Fi active may increase battery use.

## License

This project is licensed under the GNU General Public License v3.0.
