# KOReader Remote

KOReader Remote is a small plugin that lets you turn pages in KOReader from your phone.
It works over your local Wi-Fi network. You do not need to install an app on your phone. Open the remote website, tap left or right, and the Kindle turns the page.

## Why I made this

I made this plugin because i often place my Kindle somewhere on top of my blanket while reading in bed.
Sometimes i lie in bed like a folded protein and do not want to move my hand just to turn the page. i also often have my phone in my hand, or keep it next to my face while getting comfortable.
With KOReader Remote, i can turn pages from my phone without reaching for the Kindle every time.
This project was mostly (lel everything) vibe-coded. It started as a simple idea, then slowly turned into a working KOReader plugin. =)

## Demo

https://github.com/user-attachments/assets/f81e5089-8f5f-4a0a-93cc-433873eff57c

## Features

* Turn one page forward
* Turn one page backward
* Use a simple website on your phone
* No phone app required
* Automatically detects the Kindle's local IP address
* Shows the full connection link
* Creates a QR code that opens the remote website
* Optional server autostart
* Restarts the server after standby or resume when autostart is enabled
* Custom server port
* Opens and removes the Kindle firewall rule when needed
* Works directly from `Tools → KOReader Remote`

## Requirements

* A jailbroken Kindle
* KOReader installed
* Kindle and phone connected to the same local network
* A network that allows devices to communicate with each other

Guest Wi-Fi networks may block communication between your phone and Kindle.

## Installation

1. Download the latest `koreaderremote-*.zip` file from the Releases page.
2. Extract the ZIP file.
3. Stop KOReader Remote if an older version is running.
4. Copy the folder:
   ```text
   koreaderremote.koplugin
   ```
   into:
   ```text
   koreader/plugins/
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

When you start the server, KOReader tries to find the Kindle's current local IP address.
It then shows a link such as:

```text
http://192.168.1.42:8081/
```

Select:

```text
Show QR code
```

Scan the QR code with your phone camera.
The remote website should open directly in your phone browser.
You can also open the pairing screen again from:

```text
Tools → KOReader Remote → Pair phone / show QR code
```

Pairing in this version is only a quick way to open the correct link. It does not use a password or access token.

## Using the remote

The remote website has two large buttons:
* Left side: previous page
* Right side: next page
You can also use the left and right arrow keys when opening the page on a device with a keyboard.

## Autostart

Enable:

```text
Tools → KOReader Remote → Auto start remote server
```

When autostart is enabled:
* The server starts when KOReader starts
* The server stops when the Kindle goes into standby or suspend
* The server tries to start again after the Kindle wakes up
The QR code does not appear automatically after resume.
To show the current address again, open:

```text
Tools → KOReader Remote → Pair phone / show QR code
```

It may take a few seconds for Wi-Fi to reconnect after waking the Kindle.

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
  "version": "0.3.0",
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

* Use KOReader Remote only on a trusted local network.
* This version does not use authentication or an access token.
* Anyone who can reach the Kindle IP and port may send page-turn commands.
* The Kindle and phone must be able to communicate directly.
* Guest networks may block local device-to-device traffic.
* A fully sleeping Kindle cannot be woken through the remote server.
* The Kindle may receive a different IP address after reconnecting to Wi-Fi.
* Open the pairing screen again when the old address no longer works.
* Keeping Wi-Fi active may increase battery use.

## License

This project is licensed under the GNU Affero General Public License v3.0.
