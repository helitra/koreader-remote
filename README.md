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

- Turn one page forward
- Turn one page backward
- Use a simple website on your phone
- No phone app required
- Automatically detect the reader's local IPv4 address
- Show the full connection link
- Create a QR code that opens the remote website
- Optional server autostart
- Restart the server after standby or resume when autostart is enabled
- Use a custom server port
- Open and remove the Kindle firewall rule when needed
- Open the plugin directly from `Tools → KOReader Remote`

## Compatibility

- **Kindle:** tested
- **Kobo:** expected to work, but I have not tested it on real Kobo hardware yet
- **Other KOReader devices:** not tested yet

Feedback from other devices is very welcome. Please include the exact device model, KOReader version, and plugin version when reporting a result.

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

When you start the server, KOReader tries to find the reader's current local IP address.

It then shows a link such as:

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

Pairing is only a quick way to open the correct local link. It does not use a password or access token.

## Using the remote

The remote website has two large buttons:

- Left side: previous page
- Right side: next page

You can also use the left and right arrow keys on a device with a keyboard.

## Autostart

Enable:

```text
Tools → KOReader Remote → Auto start remote server
```

When autostart is enabled:

- The server starts when KOReader starts
- The server stops when the reader enters standby or suspend
- The server tries to start again after the reader wakes up

The QR code does not appear automatically after resume.

To show the current address again, open:

```text
Tools → KOReader Remote → Pair phone / show QR code
```

It may take a few seconds for Wi-Fi to reconnect after waking the reader.

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

If the server is already running, the plugin stops it and starts it again on the new port.

After changing the port, the address may look like this:

```text
http://192.168.1.42:8082/
```

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
  "version": "0.4.0",
  "port": 8081,
  "autostart": false,
  "ip": "192.168.1.42",
  "url": "http://192.168.1.42:8081/"
}
```

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
- Open the pairing screen again when the old address no longer works.
- Keeping Wi-Fi active may increase battery use.

## License

This project is licensed under the GNU General Public License v3.0.
