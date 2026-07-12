# KOReader Remote

KOReader Remote is a small plugin that lets you turn pages and control supported reader settings in KOReader from your phone.

It works over your local Wi-Fi network. You do not need to install an app on your phone. Start the remote server, scan the QR code, and use the remote website in your browser.

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
- Control supported frontlight, brightness, warmth, night mode, and full refresh functions
- Hide unsupported controls automatically
- Show compact server and network diagnostics in KOReader
- Use a configurable server port
- Open and remove the Kindle firewall rule when needed
- Open the plugin directly from `Tools → KOReader Remote`

## Compatibility

- **Kindle:** primary test platform
- **Kobo:** expected to work, but real-device feedback is still needed
- **Other KOReader devices:** device controls appear only when KOReader reports support

Please include the exact device model, KOReader version, and plugin version when reporting compatibility results.

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

## Using the remote

The upper part of the website contains two large page buttons:

- Left side: previous page
- Right side: next page

You can also use the left and right arrow keys on a device with a keyboard.

Open **Gerätesteuerung** below the page buttons to access the controls supported by the current reader:

- Frontlight on or off
- Brightness
- Warm-light level
- KOReader night mode
- Full-screen refresh

Unsupported controls are not shown. The sliders wait briefly before sending a change so that moving them does not flood the reader with requests.

When no book is open, the server remains available but page-turn requests return `409 Conflict`. Device controls can still work from the file manager when KOReader and the device support them.

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

The phone website checks the connection automatically and reloads the current device state after reconnecting. Passive status checks do not reset KOReader's sleep timer.

If the reader wakes with the same IP address, the existing browser page should reconnect without a manual reload. If the IP address changed, scan the current QR code again.

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

KOReader Remote provides a small, restricted local HTTP API. It does not expose arbitrary KOReader events.

### Existing endpoints

```http
GET /api/ping
GET /api/next
GET /api/previous
```

### Capabilities

```http
GET /api/v1/capabilities
```

Example:

```json
{
  "ok": true,
  "version": "0.6.0",
  "capabilities": {
    "page_turn": true,
    "frontlight": true,
    "brightness": true,
    "warmth": true,
    "night_mode": true,
    "full_refresh": true
  }
}
```

### Device state

```http
GET /api/v1/device-state
```

The response contains only state supported by the current device.

### Device actions

The lightweight KOReader TCP server reads the request line and headers, so action values are sent as query parameters on restricted `POST` routes:

```http
POST /api/v1/frontlight/toggle
POST /api/v1/frontlight?enabled=true
POST /api/v1/brightness?value=65
POST /api/v1/warmth?value=40
POST /api/v1/night-mode?enabled=true
POST /api/v1/night-mode/toggle
POST /api/v1/full-refresh
```

Brightness and warmth values use a simple `0` to `100` scale. The plugin converts brightness to the current device's native range. A brightness value of `0` switches the frontlight off.

## Security notes

- Use KOReader Remote only on a trusted local network.
- This version does not use authentication or an access token.
- Anyone who can reach the reader IP and port may use the available controls.
- Reader and phone must be able to communicate directly.
- Guest networks may block local device-to-device traffic.
- A fully sleeping reader cannot be woken through the remote server.
- Keeping Wi-Fi active may increase battery use.

## Releases

The GitHub Actions workflow validates normal pushes. A manually started release run reads `VERSION`, creates the matching Git tag, builds the plugin-only ZIP and SHA-256 checksum, and publishes the matching `CHANGELOG.md` section directly as the GitHub release description.

## License

This project is licensed under the GNU General Public License v3.0.
